#!/bin/bash
 
POD="clickhouse-shard0-0"
NAMESPACE="nwdaf"
CONTAINER="clickhouse"
 
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
 
CSV="ai_cell_usage_1m.csv"
 
echo "✅ 쿼리 > ${CSV}"
 
## 시작시간과 종료시간 설정
echo "
WITH
   toStartOfMinute(now()) - INTERVAL 210 MINUTE AS start_time,
   start_time + INTERVAL 200 MINUTE AS end_time
SELECT
   *
FROM ai.cell_usage_1m
WHERE window_end > start_time AND window_end <= end_time
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