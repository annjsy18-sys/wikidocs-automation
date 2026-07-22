#!/bin/bash
# 사용법:
#   ./run.sh "01" "세탁세제 TOP5" "퍼실 액체세제" "타이드 파즈 캡슐세제" "아토팜 베이비 세탁세제" "LG 테크 드럼세탁기 전용 세제" "비트 액체세제 리필 대용량"
#
# 순서:
#   1) shared/coupang_api.py로 키워드 검색 → posts/coupang_search_results.json
#   2) claude -p 로 prompt.md + json 데이터를 참고해 원고 작성 → posts/<제목>.md
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

# 1) 쿠팡 상품 검색
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
"$PYTHON_CMD" "$API_SCRIPT_PATH" "${KEYWORDS[@]}" --limit 5 --out "$JSON_PATH_WIN"

# 2) 원고 작성 (claude -p 헤드리스 모드)
echo "== 2단계: 원고 작성 =="

EXTRA_PRODUCT_INSTRUCTION="
추가 상품 추천: 스토어 링크(### 소제목) 바로 위에, 오늘 글에서 이미
소개한 상품들과는 다른 상품을 ${JSON_PATH}에서 하나 더 골라줘
(같은 키워드의 다른 순위 상품이거나, 다른 키워드의 상품이어도 됨.
품절 상품은 고르지 않는다). 아래 형식으로 자연스럽게 한 줄 넣어줘:
'💡 이런 것도 함께 보면 좋아요: [<상품명>](productUrl 값)'
JSON에 쓸 만한 다른 상품이 전혀 없으면 이 항목은 생략해도 된다.
"

claude -p "
${BLOG_DIR}/prompt.md 의 글쓰기 규칙을 그대로 지켜서
'${POST_TITLE}' 글을 작성해줘.

입력 데이터: ${JSON_PATH} 파일을 읽어서 각 키워드의 rank=1 상품을 기본으로 사용해줘.
- productName, productImage, productUrl은 이 파일 값을 그대로 써야 해. 지어내지 마.
- 이미지는 productImage에 있는 쿠팡 원본 URL을 그대로 마크다운 문법
  ![상품명](productImage 값) 으로 넣어줘 (재호스팅 하지 마). <img> 같은
  HTML 태그는 위키독스에서 안 보이니 절대 쓰지 마.
- 품절/재고 없는 상품은 추천 목록에서 제외해줘.
- 저장하기 전에 글 전체를 한 번 더 읽어보면서 오탈자, 비문, 어색한 조사
  사용이 없는지 스스로 검토하고 고쳐줘.
${EXTRA_PRODUCT_INSTRUCTION}
완료되면 결과를 ${MD_PATH} 로 저장해줘.
" --model claude-haiku-4-5 --allowedTools "Read,Write" --permission-mode acceptEdits

if [ ! -f "$MD_PATH" ]; then
  echo "❌ 원고 파일이 생성되지 않았습니다: $MD_PATH"
  echo "   (성공했다고 나와도 실제로 파일이 없으면 실패로 처리)"
  exit 1
fi

echo "API 안정화를 위해 45초 대기 후 발행합니다..."
sleep 45

# 3) 위키독스 발행
echo "== 3단계: 위키독스 발행 =="
PUBLISH_OUTPUT=$(claude -p "
${MD_PATH} 파일 내용으로 위키독스 블로그 글을 등록해줘.
제목은 '${POST_TITLE}'로 정확히 등록해줘 (본문 안에 제목을 H2로 중복해서 넣지 마).

태그는 아래 기준으로 글 내용을 보고 자동으로 생성해서 설정해줘:
- '생활용품'은 항상 포함
- 글에서 다루는 상품 카테고리 (예: 제습기, 선풍기, 세탁세제 등)
- 계절/상황 키워드 (예: 여름가전, 장마, 캠핑 등 글 내용에 맞는 것)
- 쿠팡파트너스는 절대 넣지 않는다
총 5~7개 태그를 설정해줘. 태그 설정 후 실제로 붙어있는지 확인하고,
안 붙으면 이유를 PUBLISH_RESULT 뒤에 간단히 남겨줘 (예: 태그 미적용-이유설명).

발행 전에 대가성 문구가 본문 맨 첫 줄에 인용구(blockquote, '>' 기호) 형식으로,
너무 크지 않은 일반 텍스트 크기로 들어가 있는지, 하단에도 한 번 더 있는지 확인해줘.
본문에 상품 이미지가 마크다운 이미지 문법(![]())으로 들어가 있는지, img 같은 HTML
태그가 그대로 텍스트로 남아있지 않은지도 확인해줘 (있다면 마크다운 문법으로 고쳐줘).

중요: 위키독스 MCP 도구를 실제로 호출해서 글을 등록해야 해.
글이 실제로 등록됐는지 최종 확인한 뒤, 반드시 아래 형식으로
응답의 마지막 두 줄에 결과를 적어줘 (다른 텍스트 없이 이 형식 그대로):
- 성공하면:
  PUBLISH_RESULT: SUCCESS
  PUBLISHED_URL: <실제 등록된 글의 전체 URL>
- 실패하거나 MCP 도구를 쓸 수 없으면:
  PUBLISH_RESULT: FAILED <이유>
" --model claude-haiku-4-5 --allowedTools "Read,mcp__wikidocs__*" --permission-mode acceptEdits)

echo "$PUBLISH_OUTPUT"

if ! echo "$PUBLISH_OUTPUT" | grep -q "PUBLISH_RESULT: SUCCESS"; then
  echo "❌ 위키독스 발행 실패로 확인됨 (finished로 옮기지 않음)"
  echo "$PUBLISH_OUTPUT" | grep "PUBLISH_RESULT" || echo "   (PUBLISH_RESULT 마커를 찾지 못함 — MCP 권한 문제일 수 있음)"

  if echo "$PUBLISH_OUTPUT" | grep -q "발행 가능 건수"; then
    echo "$DAILY_LIMIT" > "$COUNT_FILE"
    echo "⏸️  하루 발행 제한에 도달한 것으로 보입니다. 오늘은 더 이상 시도하지 않습니다."
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