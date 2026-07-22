#!/bin/bash
# 사용법:
#   ./run.sh "01" "세탁세제 TOP5" "퍼실 액체세제" "타이드 파즈 캡슐세제" "아토팜 베이비 세탁세제" "LG 테크 드럼세탁기 전용 세제" "비트 액체세제 리필 대용량"
#
# 순서:
#   1) shared/coupang_api.py로 키워드 검색 (limit 3으로 축소) → posts/coupang_search_results.json
#   2) claude -p 로 prompt.md + 간소화된 json 데이터를 참고해 원고 작성 → posts/<제목>.md
#   3) claude -p 로 위키독스 MCP를 통해 발행 → 성공하면 finished/로 이동
#   4) titles.txt에 오늘 제목 기록 (다음 글이 안 겹치게)
#
# 주의: Windows에서는 Git Bash 또는 WSL에서 실행하세요.

set -e

BLOG_DIR="$1"
POST_TITLE="$2"
shift 2
KEYWORDS=("$@")

if [ -z "$BLOG_DIR" ] || [ -z "$POST_TITLE" ] || [ ${#KEYWORDS[@]} -eq 0 ]; then
  echo "사용법: ./run.sh <블로그폴더> <글제목> <키워드1> <키워드2> ..."
  exit 1
fi

SLUG=$(echo "$POST_TITLE" | tr ' ' '-' | tr -cd 'a-zA-Z0-9가-힣-')
POSTS_DIR="$BLOG_DIR/posts"
FINISHED_DIR="$BLOG_DIR/finished"
TITLES_FILE="$BLOG_DIR/titles.txt"
JSON_PATH="$POSTS_DIR/coupang_search_results_${SLUG}.json"
JSON_PATH_WIN=$(cygpath -w "$JSON_PATH" 2>/dev/null || echo "$JSON_PATH")
MD_PATH="$POSTS_DIR/${SLUG}.md"

mkdir -p "$POSTS_DIR" "$FINISHED_DIR"
touch "$TITLES_FILE"

# 0-0) 하루 발행 제한(10건) 체크
DAILY_LIMIT=10
COUNT_FILE="$BLOG_DIR/.publish_count_$(date +%Y%m%d).txt"
CURRENT_COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)

if [ "$CURRENT_COUNT" -ge "$DAILY_LIMIT" ]; then
  echo "⏸️  오늘 위키독스 발행 가능 건수(${DAILY_LIMIT}건)를 이미 채웠습니다. (현재 ${CURRENT_COUNT}건)"
  echo "   내일 다시 시도해주세요. 스크립트를 종료합니다."
  exit 0
fi

# 0) 제목 중복 체크
if grep -qF "$POST_TITLE" "$TITLES_FILE" 2>/dev/null; then
  echo "⚠️  이미 쓴 제목과 겹칩니다: $POST_TITLE"
  echo "   (계속 진행하려면 이 체크를 무시하고 스크립트를 수정하세요)"
  exit 1
fi

# 1) 쿠팡 상품 검색 (토큰 절감을 위해 --limit 3으로 축소)
echo "== 1단계: 쿠팡 상품 검색 =="
if command -v python >/dev/null 2>&1 && python --version >/dev/null 2>&1; then
  PYTHON_CMD="python"
elif command -v py >/dev/null 2>&1 && py --version >/dev/null 2>&1; then
  PYTHON_CMD="py"
elif command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
  PYTHON_CMD="python3"
else
  echo "❌ 사용 가능한 파이썬 명령어를 찾을 수 없습니다 (python / py / python3 모두 실패)."
  exit 1
fi

# 윈도우 경로 호환성을 위해 cygpath 활용
API_SCRIPT_PATH=$(cygpath -w "./shared/coupang_api.py" 2>/dev/null || echo "./shared/coupang_api.py")
"$PYTHON_CMD" "$API_SCRIPT_PATH" "${KEYWORDS[@]}" --limit 3 --out "$JSON_PATH_WIN"

# 2) 원고 작성 (claude -p 헤드리스 모드 - 하이쿠 모델 적용)
echo "== 2단계: 원고 작성 =="

EXTRA_PRODUCT_INSTRUCTION="
추가 상품 추천: 소제목 바로 위에, 오늘 글에서 이미 소개한 상품들과는 다른 상품을 ${JSON_PATH}에서 하나 더 골라줘 (품절 상품 제외). 아래 형식으로 한 줄 넣어줘:
'💡 이런 것도 함께 보면 좋아요: [<상품명>](productUrl 값)'
"

claude -p "
${BLOG_DIR}/prompt.md 의 규칙에 따라 '${POST_TITLE}' 글을 작성해줘.

입력 데이터(${JSON_PATH})의 rank=1 상품을 기본으로 사용하되, 파일의 상품명, 이미지URL, 상품URL 값을 그대로 정확히 써서 ${MD_PATH} 로 저장해줘. (<img> 등 HTML 태그 금지, 마크다운 이미지 사용)
${EXTRA_PRODUCT_INSTRUCTION}
" --model claude-haiku-4-5 --allowedTools "Read,Write" --permission-mode acceptEdits

if [ ! -f "$MD_PATH" ]; then
  echo "❌ 원고 파일이 생성되지 않았습니다: $MD_PATH"
  exit 1
fi

echo "API 안정화를 위해 30초 대기 후 발행합니다..."
sleep 30

# 3) 위키독스 발행 (하이쿠 모델 적용 및 프롬프트 압축으로 입력 토큰 절감)
echo "== 3단계: 위키독스 발행 =="
PUBLISH_OUTPUT=$(claude -p "
${MD_PATH} 내용을 위키독스 블로그에 제목 '${POST_TITLE}'로 등록해줘. (본문 내 H2 제목 중복 생성 금지)

- 태그: '생활용품' 포함 총 5~7개 자동 생성 (쿠팡파트너스 태그 금지)
- 필수 검수: 대가성 문구(> 형식) 상하단 배치 확인, 상품 이미지 마크다운(![]()) 변환 확인.

중요: 위키독스 MCP 도구를 실제로 호출해 등록하고, 응답 마지막 두 줄에 아래 형식만 출력해줘:
- 성공 시:
  PUBLISH_RESULT: SUCCESS
  PUBLISHED_URL: <전체 URL>
- 실패 시:
  PUBLISH_RESULT: FAILED <이유>
" --model claude-haiku-4-5 --allowedTools "Read,mcp__wikidocs__*" --permission-mode acceptEdits)

echo "$PUBLISH_OUTPUT"

if ! echo "$PUBLISH_OUTPUT" | grep -q "PUBLISH_RESULT: SUCCESS"; then
  echo "❌ 위키독스 발행 실패로 확인됨"
  echo "$PUBLISH_OUTPUT" | grep "PUBLISH_RESULT" || echo "   (PUBLISH_RESULT 마커를 찾지 못함)"

  if echo "$PUBLISH_OUTPUT" | grep -q "발행 가능 건수"; then
    echo "$DAILY_LIMIT" > "$COUNT_FILE"
    echo "⏸️  하루 발행 제한 도달."
  fi

  exit 1
fi

PUBLISHED_URL=$(echo "$PUBLISH_OUTPUT" | grep "PUBLISHED_URL:" | sed 's/^PUBLISHED_URL: *//' | tail -1)

# 4) 성공 후처리
mv "$MD_PATH" "$FINISHED_DIR/"
if [ -n "$PUBLISHED_URL" ]; then
  echo "${POST_TITLE}|${PUBLISHED_URL}" >> "$TITLES_FILE"
else
  echo "$POST_TITLE" >> "$TITLES_FILE"
fi

echo $((CURRENT_COUNT + 1)) > "$COUNT_FILE"

echo "✅ 완료: $POST_TITLE"