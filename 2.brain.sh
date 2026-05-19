#!/bin/bash
# ==============================================================================
# [모듈 이름] 2.brain.sh - AI 분석 엔진 (SRE 리포트 분석 도구)
#
# [주요 기능]
# 1. 입력된 텍스트 리포트를 바탕으로 AI(LLM) 분석 수행
# 2. 로컬 LLM(Ollama), 상용 API(OpenAI 등), AWS Bedrock 연동 지원
# 3. 분석 소요 시간 측정 및 결과 출력
#
# [단독 사용 방법]
#   1. 파일 또는 텍스트를 파이프로 전달:
#      $ cat report.txt | ./2.brain.sh
#      $ echo "Node 1: CPU 90%!!" | ./2.brain.sh
#
#   2. AI 설정을 환경 변수로 직접 지정하여 실행:
#      $ echo "Data..." | AI_TYPE="api" AI_MODEL="gpt-4o" AI_API_KEY="sk-..." ./2.brain.sh
#
#   3. AWS Bedrock 사용:
#      $ echo "Data..." | AI_TYPE="bedrock" AI_MODEL="arn:aws:bedrock:..." AWS_REGION="ap-northeast-2" ./2.brain.sh
#
#   4. 커스텀 프롬프트 사용:
#      $ echo "Data..." | AI_PROMPT="Custom prompt here" ./2.brain.sh
#
#   5. 환경변수 파일에 설정 후 실행:
#      $ cat report.txt | ./2.brain.sh prod.env
# ==============================================================================

# 0. 설정 로드
ENV_FILE=${1:-"./0.env"}
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

# 1. 기본값 설정
AI_TYPE=${AI_TYPE:-"local"}
AI_MODEL=${AI_MODEL:-"qwen3.5:9b"}
AI_API_URL=${AI_API_URL:-"http://localhost:11434"}
AI_API_KEY=${AI_API_KEY:-"not-needed"}
AWS_REGION=${AWS_REGION:-"us-east-1"}

REPORT_TEXT=$(cat -)
if [ -z "$REPORT_TEXT" ]; then
    echo "[Error] No input text provided." >&2
    exit 1
fi

# 2. 프롬프트 설정 (환경변수 우선, 없으면 기본 프롬프트 사용)
if [ -z "$AI_PROMPT" ]; then
    # 기본 프롬프트 (한글+중국어 혼합)
    AI_PROMPT="
### Qwen Ultra-Stable SRE Analysis Prompt

# Role
你是一位冷静의 SRE 专家。只看事实，不废话。

# Task (Strict Priority)
1. 统计节点总数 (Total Nodes)。
2. 对比今日/昨日指标，找显著差异 (Diff check)。
3. 找出 CPU/Mem/Disk > 80% 或 Network/IO 异常的节点。

# Constraint (To Prevent Crash)
- Output Language: Korean (한국어)
- No Reasoning: 禁止输出推理过程，直接出结果。
- Plain Text Only: 禁止任何 Markdown 装饰 (No bold, no tables, no hashtags)。
- Max Conciseness: 用最少的文字表达。
- No Excuse: 禁止解释数据缺失(如 Error counts)。直接忽略缺失指标，禁止输出 'Input data doesn't provide' 등废话。

# Standard
- > 80%: Warning
- > 90%: Critical
- Network Error > 0.1% / IO Wait > 10%: Abnormal

# Format Example
분석 노드 수: 00개
전일 대비 변동: CPU 평균 5% 상승 등
특이 사항:
- Node-A: CPU 85% (Warning)
- Node-B: Disk IO Wait 12% (Abnormal)
"
fi

# 최종 프롬프트 생성 (데이터 추가)
PROMPT="${AI_PROMPT}

# Input Data
$REPORT_TEXT"


# 시간 측정 시작
START_TIME=$SECONDS

echo "[AI] 분석을 시작합니다 (Model: $AI_MODEL)..." >&2

if [ "$AI_TYPE" == "local" ]; then
    ENDPOINT="${AI_API_URL}/api/generate"
    PAYLOAD=$(jq -n --arg p "$PROMPT" --arg m "$AI_MODEL" '{model: $m, prompt: $p, stream: false}')
    
    RESPONSE=$(curl -sS -X POST "$ENDPOINT" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" \
      --connect-timeout 5 \
      --max-time 120)

    if [ $? -ne 0 ]; then
        echo "[Error] AI 서버와 연결할 수 없습니다. 주소나 포트를 확인하세요 ($AI_API_URL)." >&2
        exit 1
    fi

    RESULT=$(echo "$RESPONSE" | jq -r '.response // .error')
    IN_TOKENS=$(echo "$RESPONSE" | jq -r '.prompt_eval_count // 0')
    OUT_TOKENS=$(echo "$RESPONSE" | jq -r '.eval_count // 0')

elif [ "$AI_TYPE" == "api" ]; then
    ENDPOINT="${AI_API_URL}/chat/completions"
    PAYLOAD=$(jq -n --arg p "$PROMPT" --arg m "$AI_MODEL" '{model: $m, messages: [{role: "system", content: "You are a senior SRE engineer."}, {role: "user", content: $p}]}')
    
    RESPONSE=$(curl -sS -X POST "$ENDPOINT" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $AI_API_KEY" \
      -d "$PAYLOAD" \
      --connect-timeout 10 \
      --max-time 60)

    if [ $? -ne 0 ]; then
        echo "[Error] API 서버 호출에 실패했습니다." >&2
        exit 1
    fi

    RESULT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // .error.message')
    IN_TOKENS=$(echo "$RESPONSE" | jq -r '.usage.prompt_tokens // 0')
    OUT_TOKENS=$(echo "$RESPONSE" | jq -r '.usage.completion_tokens // 0')

elif [ "$AI_TYPE" == "bedrock" ]; then
    # AWS Bedrock 호출 (AWS CLI 필요)
    if ! command -v aws &> /dev/null; then
        echo "[Error] AWS CLI가 설치되지 않았습니다. 'aws' 명령어를 사용할 수 없습니다." >&2
        exit 1
    fi

    # 임시 파일 생성
    TEMP_INPUT=$(mktemp)
    TEMP_OUTPUT=$(mktemp)
    TEMP_ERROR=$(mktemp)

    # 프롬프트를 JSON string으로 변환
    PROMPT_JSON=$(echo "$PROMPT" | jq -Rs .)

    # JSON payload 생성
    cat > "$TEMP_INPUT" <<EOF
{
  "anthropic_version": "bedrock-2023-05-31",
  "max_tokens": 4096,
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": $PROMPT_JSON
        }
      ]
    }
  ]
}
EOF

    # 셸에서 한 번만 실행(API KEY가 있으면 인증경로 꼬일 수 있으므로 임시제거)
    unset AWS_BEDROCK_API_KEY AWS_BEARER_TOKEN_BEDROCK BEDROCK_API_KEY

    # AWS Bedrock InvokeModel 호출
    aws bedrock-runtime invoke-model \
      --model-id "$AI_MODEL" \
      --body "fileb://$TEMP_INPUT" \
      --region "$AWS_REGION" \
      "$TEMP_OUTPUT" 2>"$TEMP_ERROR" >/dev/null

    AWS_EXIT_CODE=$?

    if [ $AWS_EXIT_CODE -ne 0 ]; then
        echo "[Error] AWS Bedrock 호출에 실패했습니다." >&2
        echo "" >&2
        echo "[상세 에러 메시지]" >&2
        cat "$TEMP_ERROR" >&2
        echo "" >&2
        echo "[디버깅 정보]" >&2
        echo "  Model ID: $AI_MODEL" >&2
        echo "  Region: $AWS_REGION" >&2
        echo "  AWS CLI 버전: $(aws --version 2>&1)" >&2
        echo "" >&2
        echo "[해결 방법]" >&2
        echo "  1. AWS 인증 확인: aws sts get-caller-identity" >&2
        echo "  2. Bedrock 권한 확인: bedrock:InvokeModel 권한 필요" >&2
        echo "  3. 모델 액세스 확인: AWS Console > Bedrock > Model access" >&2
        rm -f "$TEMP_INPUT" "$TEMP_OUTPUT" "$TEMP_ERROR"
        exit 1
    fi

    # 응답 파싱 (Claude 모델의 응답 형식)
    # type이 "text"인 content만 추출하여 메타데이터 제외
    RESULT=$(jq -r '[.content[] | select(.type == "text") | .text] | join("\n")' "$TEMP_OUTPUT")
    IN_TOKENS=$(jq -r '.usage.input_tokens // 0' "$TEMP_OUTPUT")
    OUT_TOKENS=$(jq -r '.usage.output_tokens // 0' "$TEMP_OUTPUT")

    # 디버깅: 응답이 비어있으면 전체 응답 출력
    if [ -z "$RESULT" ] || [ "$RESULT" == "null" ]; then
        echo "[Error] Bedrock 응답을 파싱할 수 없습니다." >&2
        echo "[원본 응답]" >&2
        cat "$TEMP_OUTPUT" >&2
        rm -f "$TEMP_INPUT" "$TEMP_OUTPUT" "$TEMP_ERROR"
        exit 1
    fi

    # 임시 파일 삭제
    rm -f "$TEMP_INPUT" "$TEMP_OUTPUT" "$TEMP_ERROR"
fi

# 최종 결과 검증 및 출력
if [ -z "$RESULT" ] || [ "$RESULT" == "null" ]; then
    echo "[Error] AI로부터 응답을 받지 못했습니다. 서버 로그를 확인하세요." >&2
    echo "Raw Response: $RESPONSE" >&2
    exit 1
fi

# 시간 측정 종료 및 계산
DURATION=$((SECONDS - START_TIME))

echo "$RESULT"
echo "[AI] 분석이 완료되었습니다. (소요 시간: ${DURATION}초, 토큰: in=${IN_TOKENS:-0} out=${OUT_TOKENS:-0} total=$((${IN_TOKENS:-0}+${OUT_TOKENS:-0})))" >&2
