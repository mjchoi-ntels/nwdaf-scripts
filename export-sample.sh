#!/bin/bash
 
 
POD="clickhouse-shard0-0"
NAMESPACE="nwdaf"
CONTAINER="clickhouse"
 
if oc exec -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- ls / >/dev/null 2>&1; then
  echo "✅ 권한 확인"
else
  echo "❌ 권한 없음"
  exit 1
fi
 
INPUT="$1"
 
# 입력값 존재 및 형식 확인
if [[ ! "$INPUT" =~ ^[0-9]{6}$ ]]; then
  echo "❌ 형식 오류: YYMMDD 형태(예: 251020)로 입력하세요."
  exit 1
fi
 
DATE="20${INPUT:0:2}-${INPUT:2:2}-${INPUT:4:2}"
 
if ! date -d "$DATE" >/dev/null 2>&1; then
  echo "❌ 유효하지 않은 날짜입니다: $DATE"
  exit 1
fi
 
NEXT_DATE=$(date -d "$DATE +1 day" +"%Y-%m-%d")
 
CSV="sample_hist_5m_${INPUT}.total.csv"
 
echo "✅ 쿼리 > ${CSV}"
 
echo "WITH
    '${DATE} 00:00:00' AS start_time,
    '${NEXT_DATE} 00:00:00' AS end_time
SELECT
    cell_type,
    freq_type,
    window_end,
    prb_usage_rate,
    enb_cell_id,
    day_of_week,
    total_user_usage_5m,
    heavy_user_usage_5m
FROM ai.cell_usage_hist_5m
PREWHERE
    window_start >= start_time AND
    window_start < end_time
ORDER BY enb_cell_id, window_end
FORMAT CSV" | oc exec -i -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- bash -c 'clickhouse client --password ${CLICKHOUSE_ADMIN_PASSWORD}' > ${CSV}
 
echo "✅ xz 압축"
 
xz -T 4 -2 -kv ${CSV}