#!/bin/bash
## ./export-ai-cell-usage-1m.sh [YYMMDDHH]
 
POD="clickhouse-shard0-0"
NAMESPACE="nwdaf"
CONTAINER="clickhouse"

# 인자 검증
if [ -z "$1" ]; then
  echo "ERROR: YYMMDDHH 인자가 필요합니다." >&2
  echo "사용법: $0 YYMMDDHH" >&2
  echo "예시: $0 26031800 (2026-03-18 00시)" >&2
  exit 1
fi

YYMMDDHH="$1"

# 인자 형식 검증 (8자리 숫자)
if ! [[ "$YYMMDDHH" =~ ^[0-9]{8}$ ]]; then
  echo "ERROR: YYMMDDHH는 8자리 숫자여야 합니다. (예: 26031800)" >&2
  exit 1
fi

# YYMMDDHH 파싱
YY="${YYMMDDHH:0:2}"
MM="${YYMMDDHH:2:2}"
DD="${YYMMDDHH:4:2}"
HH="${YYMMDDHH:6:2}"

# 날짜 형식 생성 (UTC 기준)
START_TIME="20${YY}-${MM}-${DD} ${HH}:00:00"
# 1시간 후 계산 (00:00:00 <= window_end < 01:00:00)
NEXT_HH=$(printf "%02d" $(( 10#${HH} + 1 )))
if [ "$NEXT_HH" -eq 24 ]; then
  # 다음 날로 넘어가는 경우 처리
  END_TIME=$(date -d "20${YY}-${MM}-${DD} +1 day" '+%Y-%m-%d 00:00:00' 2>/dev/null || echo "20${YY}-${MM}-${DD} 23:59:59")
else
  END_TIME="20${YY}-${MM}-${DD} ${NEXT_HH}:00:00"
fi

# 파일명에 날짜 포함
CSV="ai_cell_usage_1m_${YYMMDDHH}.csv"
 
if command -v oc >/dev/null 2>&1; then
  CMD=oc
elif command -v kubectl >/dev/null 2>&1; then
  CMD=kubectl
else
  echo "ERROR: neither 'oc' nor 'kubectl' found in PATH." >&2
  exit 1
fi
 
if ${CMD} exec -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- ls / >/dev/null 2>&1; then
  echo "✅ 권한 확인"
else
  echo "❌ 권한 없음"
  exit 1
fi

echo "✅ 쿼리 실행: ${START_TIME} ~ ${END_TIME} (UTC)"
echo "✅ 출력 파일: ${CSV}"
 
## 지정된 시간의 데이터 추출 (1시간: START_TIME <= window_end < END_TIME)
echo "
SELECT
   *
FROM ai.cell_usage_1m
WHERE window_end >= '$START_TIME' AND window_end < '$END_TIME'
ORDER BY enb_cell_id, window_end
FORMAT CSVWithNames;" | ${CMD} exec -i -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- bash -c 'clickhouse client --password ${CLICKHOUSE_ADMIN_PASSWORD}' > ${CSV}
 
 
xz -T 4 -2 -kv ${CSV}




------------------

WITH
   toStartOfMinute(now()) - INTERVAL 20 MINUTE AS start_time,
   start_time + INTERVAL 10 MINUTE AS end_time
SELECT
   *
FROM ai.cell_usage_1m
WHERE window_end > start_time AND window_end <= end_time
ORDER BY enb_cell_id, window_end