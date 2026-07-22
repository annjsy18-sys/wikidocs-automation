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
# grep -c가 여러 줄/빈 값을 반환하는 경우 대비, 숫자가 아니면 0으로 강제
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
claude -p "
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
" --model claude-haiku-4-5 --allowedTools "Read,Write" --permission-mode acceptEdits

if [ ! -f "${BLOG_DIR}/today_topics.txt" ]; then
  echo "❌ 주제 파일이 생성되지 않았습니다. 중단합니다." | tee -a "$LOG_FILE"
  exit 1
fi

# 2) 한 줄씩 읽어서 run.sh 반복 실행
COUNT=0
while IFS='|' read -r TITLE KEYWORDS_RAW; do
  [ -z "$TITLE" ] && continue
  if [ "$COUNT" -ge "$REMAINING" ]; then
    break
  fi

  # 쉼표로 구분된 키워드를 배열로 변환
  IFS=',' read -ra KEYWORDS <<< "$KEYWORDS_RAW"

  echo "== [$((COUNT+1))/${REMAINING}] '$TITLE' 발행 시작 ==" | tee -a "$LOG_FILE"

  if ./run.sh "$BLOG_DIR" "$TITLE" "${KEYWORDS[@]}" >> "$LOG_FILE" 2>&1; then
    echo "[$TODAY] $TITLE" >> "$TITLES_FILE"
    echo "✅ 성공: $TITLE" | tee -a "$LOG_FILE"
    COUNT=$((COUNT+1))
  else
    echo "❌ 실패: $TITLE (로그 확인: $LOG_FILE)" | tee -a "$LOG_FILE"
  fi

  # 너무 기계적으로 보이지 않게, 기본 60초 + 무작위 0~60초 추가 대기
  if [ "$COUNT" -lt "$REMAINING" ]; then
    WAIT=$((180 + RANDOM % 60))  # 180초~240초(3~4분) 대기 — API TPM 제한 안전마진
    echo "다음 글까지 ${WAIT}초 대기..." | tee -a "$LOG_FILE"
    sleep "$WAIT"
  fi
done < "${BLOG_DIR}/today_topics.txt"

rm -f "${BLOG_DIR}/today_topics.txt"
echo "== $(date) 배치 종료: 오늘 총 ${COUNT}개 발행 ==" | tee -a "$LOG_FILE"