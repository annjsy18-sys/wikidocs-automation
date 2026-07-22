#!/bin/bash
# 하루치(기본 10개) 글을 순서대로 자동으로 쓰고 발행하는 배치 스크립트.
# 작업 스케줄러가 매일 이 파일 하나만 실행하면 됩니다.
#
# 사용법: ./daily_batch.sh "01" 10
#   $1 = 블로그 폴더 (예: 01)
#   $2 = 오늘 발행할 개수 (기본 10, 위키독스 하루 발행 한도를 넘지 않게 조정)

set -e

BLOG_DIR="${1:-01}"
TARGET_COUNT="${2:-10}"
TITLES_FILE="$BLOG_DIR/titles.txt"
LOG_FILE="$BLOG_DIR/daily_log_$(date +%Y%m%d).txt"

touch "$TITLES_FILE"
echo "== $(date) 배치 시작: 목표 ${TARGET_COUNT}개 ==" >> "$LOG_FILE"

# 오늘 이미 발행한 개수 세기 (titles.txt에 오늘 날짜로 기록된 줄 기준)
TODAY=$(date +%Y-%m-%d)
ALREADY_DONE=$(grep -c "^\[$TODAY\]" "$TITLES_FILE" 2>/dev/null || true)
ALREADY_DONE="${ALREADY_DONE:-0}"
case "$ALREADY_DONE" in
  ''|*[!0-9]*) ALREADY_DONE=0 ;;
esac

if [ "$ALREADY_DONE" -ge "$TARGET_COUNT" ]; then
  echo "오늘 이미 ${ALREADY_DONE}개 발행함 (목표 ${TARGET_COUNT}개). 종료." | tee -a "$LOG_FILE"
  exit 0
fi

REMAINING=$((TARGET_COUNT - ALREADY_DONE))
echo "오늘 ${ALREADY_DONE}개 완료, ${REMAINING}개 더 발행 예정" | tee -a "$LOG_FILE"

# 1) 클로드 코드에게 오늘 쓸 주제+키워드 목록을 정하게 시킴
echo "== 오늘의 주제 선정 중... ==" | tee -a "$LOG_FILE"

if claude -p "
${BLOG_DIR}/titles.txt 에 있는 기존 제목들과 안 겹치는,
아직 안 쓴 생활용품/가전 카테고리 세부 키워드로
오늘 발행할 글 주제 ${REMAINING}개를 정해줘.
지금 계절과 시기에 맞는 걸로 골라줘.

각 주제마다 '글 제목'과 '쿠팡 검색 키워드 5개'를 정해서,
아래 형식으로 ${BLOG_DIR}/today_topics.txt 파일에 저장해줘.
한 줄에 주제 하나, | 로 구분:

글제목1|키워드1,키워드2,키워드3,키워드4,키워드5
글제목2|키워드1,키워드2,키워드3,키워드4,키워드5
...
" --model claude-haiku-4-5 --allowedTools "Read,Write" --permission-mode acceptEdits; then
  echo "클로드 명령 실행 완료"
else
  echo "❌ 클로드 명령어 실행 자체 실패" | tee -a "$LOG_FILE"
  exit 1
fi

if [ ! -f "${BLOG_DIR}/today_topics.txt" ]; then
  echo "❌ 주제 파일(${BLOG_DIR}/today_topics.txt)이 생성되지 않았습니다. 중단합니다." | tee -a "$LOG_FILE"
  exit 1
fi

# 2) 한 줄씩 읽어서 run.sh 반복 실행 (로그가 화면에 바로 보이도록 tee 활용)
COUNT=0
while IFS='|' read -r TITLE KEYWORDS_RAW; do
  [ -z "$TITLE" ] && continue
  if [ "$COUNT" -ge "$REMAINING" ]; then
    break
  fi

  IFS=',' read -ra KEYWORDS <<< "$KEYWORDS_RAW"

  echo "== [$((COUNT+1))/${REMAINING}] '$TITLE' 발행 시작 ==" | tee -a "$LOG_FILE"

  # 수정됨: 에러가 숨겨지지 않고 화면과 로그 파일에 동시에 출력되도록 변경
  if ./run.sh "$BLOG_DIR" "$TITLE" "${KEYWORDS[@]}" 2>&1 | tee -a "$LOG_FILE"; then
    echo "[$TODAY] $TITLE" >> "$TITLES_FILE"
    echo "✅ 성공: $TITLE" | tee -a "$LOG_FILE"
    COUNT=$((COUNT+1))
  else
    echo "❌ 실패: $TITLE (로그 확인: $LOG_FILE)" | tee -a "$LOG_FILE"
    exit 1
  fi

  if [ "$COUNT" -lt "$REMAINING" ]; then
    WAIT=$((180 + RANDOM % 60))
    echo "다음 글까지 ${WAIT}초 대기..." | tee -a "$LOG_FILE"
    sleep "$WAIT"
  fi
done < "${BLOG_DIR}/today_topics.txt"

rm -f "${BLOG_DIR}/today_topics.txt"
echo "== $(date) 배치 종료: 오늘 총 ${COUNT}개 발행 ==" | tee -a "$LOG_FILE"