# /// script
# requires-python = ">=3.11"
# dependencies = ["fastapi>=0.115", "uvicorn>=0.30"]
# ///
"""기존 셸 파이프라인(1.fetch.sh / 2.brain.sh)을 HTTP로 노출하는 얇은 API."""

from __future__ import annotations

import logging
import re
import subprocess
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal

import uvicorn
from fastapi import BackgroundTasks, FastAPI, HTTPException
from pydantic import BaseModel, Field

REPO_ROOT = Path(__file__).resolve().parent.parent
ENV_NAME = re.compile(r"[A-Za-z0-9._-]+\.env")
METRICS_TTL_SEC = 60
FETCH_TIMEOUT_SEC = 120
ANALYSIS_TIMEOUT_SEC = 600
JOB_HISTORY = 50

log = logging.getLogger("metric-api")

app = FastAPI(
    title="Metric LLM Reporter API",
    version="0.1.0",
    summary="Prometheus 메트릭 압축 리포트 조회 및 LLM 분석 실행",
)


class MetricsReport(BaseModel):
    env: str
    generated_at: datetime
    cached: bool
    report: str


class AnalysisRequest(BaseModel):
    env: str = Field(default="0.env", examples=["0.env", "bedrock.env"])


class Analysis(BaseModel):
    id: str
    env: str
    status: Literal["running", "succeeded", "failed"]
    created_at: datetime
    finished_at: datetime | None = None
    analysis: str | None = None
    error: str | None = None


_lock = threading.Lock()
_metrics_cache: dict[str, tuple[float, datetime, str]] = {}
_analyses: dict[str, Analysis] = {}
_running_id: str | None = None


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _resolve_env(name: str) -> str:
    """환경변수 파일은 저장소 루트의 `*.env`만 허용한다(경로 조작·임의 파일 로드 차단)."""
    if not ENV_NAME.fullmatch(name) or not (REPO_ROOT / name).is_file():
        raise HTTPException(status_code=404, detail=f"env file not found: {name}")
    return name


def _run(script: str, env_file: str, timeout: int, stdin: str | None = None) -> str:
    proc = subprocess.run(
        ["bash", script, env_file],
        cwd=REPO_ROOT,
        input=stdin,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if proc.returncode != 0:
        # stderr에는 내부 URL·자격증명이 섞일 수 있어 로그에만 남기고 응답에는 넣지 않는다.
        log.error("%s exit=%s stderr=%s", script, proc.returncode, proc.stderr.strip()[-2000:])
        raise RuntimeError(f"{script} failed (exit {proc.returncode})")
    return proc.stdout


def _fetch_metrics(env_file: str, refresh: bool) -> MetricsReport:
    with _lock:
        hit = _metrics_cache.get(env_file)
    if hit and not refresh and time.monotonic() - hit[0] < METRICS_TTL_SEC:
        return MetricsReport(env=env_file, generated_at=hit[1], cached=True, report=hit[2])

    report = _run("1.fetch.sh", env_file, FETCH_TIMEOUT_SEC)
    generated_at = _now()
    with _lock:
        _metrics_cache[env_file] = (time.monotonic(), generated_at, report)
    return MetricsReport(env=env_file, generated_at=generated_at, cached=False, report=report)


def _run_analysis(job_id: str, env_file: str) -> None:
    global _running_id
    try:
        report = _fetch_metrics(env_file, refresh=True).report
        analysis = _run("2.brain.sh", env_file, ANALYSIS_TIMEOUT_SEC, stdin=report)
        result = {"status": "succeeded", "analysis": analysis.strip()}
    except subprocess.TimeoutExpired:
        result = {"status": "failed", "error": "pipeline timed out"}
    except Exception as exc:  # noqa: BLE001 - 원문은 로그에만 남긴다
        log.exception("analysis %s failed", job_id)
        result = {"status": "failed", "error": str(exc)}

    with _lock:
        _analyses[job_id] = _analyses[job_id].model_copy(
            update={**result, "finished_at": _now()}
        )
        _running_id = None


@app.get("/healthz", tags=["ops"])
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/v1/metrics", response_model=MetricsReport, tags=["metrics"])
def get_metrics(env: str = "0.env", refresh: bool = False) -> MetricsReport:
    """LLM 입력용 압축 메트릭 리포트. 기본은 TTL 캐시를 재사용해 Prometheus 재조회를 피한다."""
    env_file = _resolve_env(env)
    try:
        return _fetch_metrics(env_file, refresh)
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="metric fetch timed out") from None
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from None


@app.post("/v1/analyses", response_model=Analysis, status_code=202, tags=["analysis"])
def create_analysis(req: AnalysisRequest, background: BackgroundTasks) -> Analysis:
    """LLM 분석을 비동기로 실행하고 즉시 job을 반환한다. 동시 실행은 1건으로 제한."""
    env_file = _resolve_env(req.env)
    global _running_id
    with _lock:
        if _running_id:
            raise HTTPException(
                status_code=409, detail=f"analysis already running: {_running_id}"
            )
        job = Analysis(id=uuid.uuid4().hex[:12], env=env_file, status="running", created_at=_now())
        _analyses[job.id] = job
        _running_id = job.id
        for stale in sorted(_analyses, key=lambda k: _analyses[k].created_at)[:-JOB_HISTORY]:
            del _analyses[stale]

    background.add_task(_run_analysis, job.id, env_file)
    return job


@app.get("/v1/analyses", response_model=list[Analysis], tags=["analysis"])
def list_analyses() -> list[Analysis]:
    with _lock:
        return sorted(_analyses.values(), key=lambda a: a.created_at, reverse=True)


@app.get("/v1/analyses/{job_id}", response_model=Analysis, tags=["analysis"])
def get_analysis(job_id: str) -> Analysis:
    with _lock:
        job = _analyses.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail=f"analysis not found: {job_id}")
    return job


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    uvicorn.run(app, host="127.0.0.1", port=8000)
