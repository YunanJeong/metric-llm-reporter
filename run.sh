#!/bin/bash
# run.sh - AI 서버 리포터 실행기

# 0. 설정 로드
ENV_FILE=${1:-"./0.env"}
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "Error: $ENV_FILE file not found." >&2
    exit 1
fi

# 1. 메트릭 추출
# PROM_URL 설정은 ENV_FILE에서 로드된 것을 사용
REPORT_TEXT=$(PROM_URL="$PROM_URL" ./1.fetch.sh "$ENV_FILE")

# 2. 결과 출력 (확인용)
echo -e "\n================ [METRICS SUMMARY] ================"
echo "$REPORT_TEXT"
echo "===================================================\n"

# 3. AI 분석 요청
# AI_TYPE, AI_MODEL, AI_API_KEY, AI_API_URL을 ENV_FILE에서 그대로 전달
ANALYSIS_RESULT=$(echo "$REPORT_TEXT" | \
    AI_TYPE="$AI_TYPE" \
    AI_MODEL="$AI_MODEL" \
    AI_API_KEY="$AI_API_KEY" \
    AI_API_URL="$AI_API_URL" \
    ./2.brain.sh "$ENV_FILE")

# 4. 헤더/푸터 설정 (여기서 직접 수정)
REPORT_HEADER=""
REPORT_FOOTER="Powered by Metric-LLM-Reporter / $(sed -E '/application-inference-profile/ s/bedrock:[^:]+:[0-9]{12}:/***:/' <<< "$AI_MODEL")"

# 5. 최종 리포트 생성
if [ -n "$ANALYSIS_RESULT" ]; then
    FINAL_REPORT="${REPORT_HEADER}

================ [AI SRE ANALYSIS] ================
${ANALYSIS_RESULT}
===================================================

${REPORT_FOOTER}"

    # 6. 콘솔 출력
    echo "$FINAL_REPORT"

    # # 7. 메일 발송
    echo "$FINAL_REPORT" | \
    RECIPIENT="$MAIL_RECIPIENT" \
    SUBJECT="$MAIL_SUBJECT ($(TZ='Asia/Seoul' date '+%Y-%m-%d %H:%M:%S %Z'))" \
    ./3.mail.sh "$ENV_FILE"
fi
