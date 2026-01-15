#!/bin/bash

## ./export-cell-group.sh [기지국그룹명]

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

CSV="cell_group.csv"

echo "✅ 쿼리 > ${CSV}"

echo "SELECT
    cell_group_id,
    cell_group_name,
    cell_type,
    cell_id
FROM nwdaf.t_cell_control_config$([ -z "${INPUT}" ] || echo "
WHERE
    cell_group_name like '%${INPUT}%'")
ORDER BY cell_type, cell_id
FORMAT CSVWithNames" | ${CMD} exec -i -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- bash -c 'clickhouse client --password ${CLICKHOUSE_ADMIN_PASSWORD}' > ${CSV}

echo "✅ xz 압축"
xz -T 4 -2 -kv ${CSV}