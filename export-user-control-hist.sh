#!/bin/bash
## ./export-user-control-hist.sh [YYMMDD]

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

CSV="user_control_send_hist_${INPUT}.csv"

echo "✅ 쿼리 > ${CSV}"

echo "WITH
    '${DATE} 00:00:00' AS start_time,
    '${NEXT_DATE} 00:00:00' AS end_time
SELECT
    *
FROM nwdaf.t_user_control_send_hist
PREWHERE
    sent_at >= start_time AND
    sent_at < end_time
ORDER BY sent_at, cell_id, mdn
FORMAT CSVWithNames" | ${CMD} exec -i -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- bash -c 'clickhouse client --password ${CLICKHOUSE_ADMIN_PASSWORD}' > ${CSV}

echo "✅ xz 압축"
 xz -T 4 -2 -kv ${CSV}