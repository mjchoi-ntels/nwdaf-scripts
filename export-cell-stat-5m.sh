#!/bin/bash

## ./export-cell-stat-5m.sh YYMMDD

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

CSV="cell_stat_5m_${INPUT}.csv"

echo "✅ 쿼리 > ${CSV}"

for i in $(seq 0 23); do
  HH=$(printf "%02d" "${i}")
  DATE_HOUR="${DATE} ${HH}:00:00"
  echo "쿼리 시간: ${DATE_HOUR}"

  echo "
  WITH
      toDateTime('${DATE_HOUR}') AS start_time,
      start_time + INTERVAL 1 HOUR AS end_time
  SELECT
      cell_id,
      cell_type,
      window_end,
      total_user,
      countIf(mdn IS NOT NULL AND user_control_qos != 'NoQoS_NoGBR') over (PARTITION BY cell_id, cell_type, window_end) AS control_user,
      total_dl,
      total_ul,
      heavy_user,
      heavy_dl,
      heavy_ul
  FROM nwdaf.stat_cell_usage
  LEFT JOIN nwdaf.t_user_control_send_hist USING (cell_id, cell_type, window_end)
  WHERE window_end > start_time AND window_end <= end_time
  ORDER BY cell_type, cell_id, window_end
  FORMAT $(if [ $i -eq 0 ]; then echo "CSVWithNames"; else echo "CSV"; fi)
  SETTINGS join_use_nulls = 1;" | \
  ${CMD} exec -i -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- bash -c 'clickhouse client --password ${CLICKHOUSE_ADMIN_PASSWORD}' | \
  ([ $i -eq 0 ] && cat > ${CSV} || cat >> ${CSV})
done

echo "✅ xz 압축"
 
xz -T 4 -2 -kv ${CSV}


#  WITH
#     '2025-11-12 00:00:00' AS start_time,
#     '2025-11-12 01:00:00' AS end_time,
#     stat_1m AS (
#         SELECT
#             cell_id,
#             cell_type,
#             window_end,
#             total_user,
#             countIf(CASE WHEN mdn IS NOT NULL AND user_control_qos != 'NoQoS_NoGBR' THEN 1 END) over (PARTITION BY cell_id, cell_type, window_end) AS control_user,
#             total_dl,
#             total_ul
#         FROM nwdaf.stat_cell_usage
#         LEFT JOIN nwdaf.t_user_control_send_hist USING (cell_id, cell_type, window_end)
#         WHERE window_end > start_time AND window_end <= end_time
#         ORDER BY cell_type, cell_id, window_end DESC
#     )
# SELECT * FROM stat_1m FORMAT NULL