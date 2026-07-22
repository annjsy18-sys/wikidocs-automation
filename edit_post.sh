#!/bin/bash
# 이미 발행된 위키독스 글 하나를 나중에 수정합니다.
# (예: <img> 태그가 그대로 노출된 경우, 태그가 안 붙은 경우 등)
#
# 사용법:
#   ./edit_post.sh "https://wikidocs.net/b/hiru/24537"
#   ./edit_post.sh "https://wikidocs.net/b/hiru/24537" "이 부분도 추가로 고쳐줘: ..."
#
# 주의: Windows에서는 Git Bash 또는 WSL에서 실행하세요.

set -e

POST_URL="$1"
EXTRA_INSTRUCTION="${2:-}"

if [ -z "$POST_URL" ]; then
  echo "사용법: ./edit_post.sh <위키독스_글_URL> [\"추가 수정 지시사항(선택)\"]"
  echo "예시:  ./edit_post.sh \"https://wikidocs.net/b/hiru/24537\""
  exit 1
fi

echo "== 위키독스 글 수정 시작: ${POST_URL} =="

EDIT_OUTPUT=$(claude -p "
${POST_URL} 위키독스 블로그 글을 불러와서 아래 문제를 확인하고 고쳐줘.

1. 본문 안에 <img ...> 같은 HTML 태그가 렌더링되지 않고 글자 그대로
   노출되어 있으면, 마크다운 이미지 문법 \`![상품명](이미지URL)\`로 바꿔줘.
   (그 태그의 src 값이 이미지 URL, alt 값이 상품명이니 그대로 재사용하면 돼.)
   이미지 URL이나 상품명을 새로 지어내지 말고, 태그 안에 있던 값을 그대로 써.
2. 이 글에 태그가 하나도 안 붙어있으면 '생활용품' 태그를 추가해줘.
3. 그 외 추가 지시사항: ${EXTRA_INSTRUCTION:-없음}

수정한 뒤 글을 다시 불러와서 실제로 반영됐는지(이미지가 정상 렌더링되는
마크다운 문법인지, 태그가 붙어있는지) 확인해줘.

중요: 반드시 위키독스 MCP 도구를 실제로 호출해서 수정해야 해.
마지막 두 줄에 아래 형식으로 결과를 적어줘 (다른 텍스트 없이 이 형식 그대로):
- 성공하면:
  EDIT_RESULT: SUCCESS
  EDITED_URL: ${POST_URL}
- 실패하거나 MCP 도구를 쓸 수 없으면:
  EDIT_RESULT: FAILED <이유>
" --allowedTools "Read,mcp__wikidocs__*" --permission-mode acceptEdits)

echo "$EDIT_OUTPUT"

if echo "$EDIT_OUTPUT" | grep -q "EDIT_RESULT: SUCCESS"; then
  echo "✅ 수정 완료: ${POST_URL}"
else
  echo "❌ 수정 실패로 확인됨"
  echo "$EDIT_OUTPUT" | grep "EDIT_RESULT" || echo "   (EDIT_RESULT 마커를 찾지 못함 — MCP 권한 문제일 수 있음)"
  exit 1
fi
