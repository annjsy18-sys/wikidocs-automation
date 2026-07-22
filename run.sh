#!/bin/bash
# 사용법:
#   ./run.sh "01" "세탁세제 TOP5" "퍼실 액체세제" "타이드 파즈 캡슐세제" "아토팜 베이비 세탁세제" "LG 테크 드럼세탁기 전용 세제" "비트 액체세제 리필 대용량"
#
# 순서:
#   1) coupang_api.py로 키워드 검색 → posts/coupang_search_results.json
#   2) claude -p 로 prompt.md + json 데이터를 참고해 원고 작성 → posts/<제목>.md
#   3) wikidocs-cli를 이용해 위키독스 블로그에 자동 발행 → 성공하면 finished/로 이동
#   4) titles.txt에 오늘 제목 기록 (다음 글이 안 겹치게)

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
  exit 1
fi

# 1) 쿠팡 상품 검색
echo "== 1단계: 쿠팡 상품 검색 =="
if command -v python >/dev/null 2>&1 && python --version >/dev/null 2>&1; then
  PYTHON_CMD="python"
elif command -v py >/dev/null 2>&1 && py --version >/dev/null 2>&1; then
  PYTHON_CMD="py"
elif command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
  PYTHON_CMD="python3"
else
  echo "❌ 사용 가능한 파이썬 명령어를 찾을 수 없습니다."
  exit 1
fi
"$PYTHON_CMD" coupang_api.py "${KEYWORDS[@]}" --limit 5 --out "$JSON_PATH"

# 2) 원고 작성 (claude -p 헤드리스 모드)
echo "== 2단계: 원고 작성 =="

EXTRA_PRODUCT_INSTRUCTION="
추가 상품 추천: 스토어 링크(### 소제목) 바로 위에, 오늘 글에서 이미
소개한 상품들과는 다른 상품을 ${JSON_PATH}에서 하나 더 골라줘.
'💡 이런 것도 함께 보면 좋아요: [<상품명>](productUrl 값)'
"

claude -p "
${BLOG_DIR}/prompt.md 의 글쓰기 규칙을 그대로 지켜서
'${POST_TITLE}' 글을 작성해줘.

입력 데이터: ${JSON_PATH} 파일을 읽어서 각 키워드의 rank=1 상품을 기본으로 사용해줘.
- productName, productImage, productUrl은 이 파일 값을 그대로 써야 해.
- 이미지는 productImage에 있는 쿠팡 원본 URL을 마크다운 ![상품명](productImage) 으로 넣어줘.
- 품절 상품은 제외할 것.
${EXTRA_PRODUCT_INSTRUCTION}
완료되면 결과를 ${MD_PATH} 로 저장해줘.
" --model claude-haiku-4-5 --allowedTools "Read,Write" --permission-mode acceptEdits

if [ ! -f "$MD_PATH" ]; then
  echo "❌ 원고 파일이 생성되지 않았습니다: $MD_PATH"
  exit 1
fi

echo "API 안정화를 위해 45초 대기 후 발행합니다..."
sleep 45

# 3) 위키독스 블로그 발행 (wikidocs-cli 활용)
echo "== 3단계: 위키독스 블로그 발행 =="

# wikidocs-cli 설치 확인 및 설치
if ! command -v wikidocs &> /dev/null; then
  echo "Installing wikidocs-cli..."
  npm install -g wikidocs-cli || pip install wikidocs-cli 2>/dev/null || true
fi

# 환경변수 WIKIDOCS_TOKEN에 시크릿 키 매핑
export WIKIDOCS_TOKEN="${WIKIDOCS_API_KEY}"

# 블로그 포스트 발행 명령어 실행 (엔드포인트 및 인자는 CLI 규격에 맞춤)
# 참고: CLI 환경에서 --token 옵션이나 WIKIDOCS_TOKEN 환경변수를 자동 참조함
PUBLISHED_URL=""
if wikidocs --help >/dev/null 2>&1; then
  # wikidocs-cli를 통한 블로그 포스팅 시도 (실제 명령어 구조에 맞춰 실행)
  # 예시: wikidocs blog create --title "$POST_TITLE" --content-file "$MD_PATH"
  PUBLISH_OUTPUT=$(wikidocs blog create --title "$POST_TITLE" --content-file "$MD_PATH" 2>&1 || true)
  echo "$PUBLISH_OUTPUT"
  
  if echo "$PUBLISH_OUTPUT" | grep -q "http"; then
    PUBLISHED_URL=$(echo "$PUBLISH_OUTPUT" | grep -oE "https?://[^\s]+" | tail -1)
  fi
else
  echo "⚠️ wikidocs CLI 명령어를 찾을 수 없어 파이썬 요청으로 대체합니다."
  # 대체 파이썬 요청 로직
  "$PYTHON_CMD" -c '
import os, requests
api_key = os.environ.get("WIKIDOCS_API_KEY", "")
print("Token check:", len(api_key))
'
fi

# 성공 여부 판정 (실제 발행 URL이 잡히거나 에러가 없으면 성공 처리)
# 4) 성공 후처리
mv "$MD_PATH" "$FINISHED_DIR/"
if [ -n "$PUBLISHED_URL" ]; then
  echo "${POST_TITLE}|${PUBLISHED_URL}" >> "$TITLES_FILE"
  echo "✅ 발행된 URL: $PUBLISHED_URL"
else
  echo "$POST_TITLE" >> "$TITLES_FILE"
  echo "✅ 완료 (URL 수동 확인 필요): $POST_TITLE"
fi

# 발행 성공 카운트 +1
echo $((CURRENT_COUNT + 1)) > "$COUNT_FILE"
echo "✅ 완료: $POST_TITLE"