#!/bin/bash
# filepath: d:\7. Personal\git\scripts\usercontrol-send-hist.sh

ENV_FILE="$(dirname "$0")/usercontrol-send-hist.env"

read -p "현재 env 파일 값을 그대로 사용할까요? (Y/n): " USE_ENV
if [[ "$USE_ENV" =~ ^[Yy]$ || -z "$USE_ENV" ]]; then
  source "$ENV_FILE"
else
  # 사용자 입력 받기
  read -p "MDN 입력(전체 조회시 Enter): " MDN

  # cell_group_id 목록 조회 및 출력
  echo "사용 가능한 Cell Group ID 목록:"
  oc exec -i -n nwdaf clickhouse-shard0-0 -c clickhouse -- bash -c \
  "echo 'SELECT id, cell_group_name FROM nwdaf.conn_pgsql_t_cell_group_config FORMAT PrettyCompact' | clickhouse client --password \${CLICKHOUSE_ADMIN_PASSWORD}"
  read -p "Cell Group ID 선택(전체 조회시 Enter): " CELL_GROUP_ID
  read -p "시작 시간 입력(예: 2025-10-29 11:00:00): " START_TIME
  read -p "종료 시간 입력(예: 2025-10-30 14:00:00): " END_TIME

  # 입력값을 env 파일에 저장
  cat > "$ENV_FILE" <<EOF
MDN="${MDN}"
CELL_GROUP_ID="${CELL_GROUP_ID}"
START_TIME="${START_TIME}"
END_TIME="${END_TIME}"
EOF

  source "$ENV_FILE"
fi

POD="clickhouse-shard0-0"
NAMESPACE="nwdaf"
CONTAINER="clickhouse"

if oc exec -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- ls / >/dev/null 2>&1; then
  echo "✅ 권한 확인"
else
  echo "❌ 권한 없음"
  exit 1
fi

# 파일명에 생성시간 반영
NOW=$(date +"%Y%m%d%H%M%S")
CSV="usercontrol_send_hist_${NOW}.csv"

echo "✅ 쿼리 > ${CSV}"

MDN_CONDITION=""
CELL_GROUP_ID_CONDITION=""

if [[ -n "$MDN" ]]; then
  MDN_CONDITION="AND mdn = '${MDN}'"
fi
if [[ -n "$CELL_GROUP_ID" ]]; then
  CELL_GROUP_ID_CONDITION="AND cell_group_id = '${CELL_GROUP_ID}'"
fi

echo "
SELECT 
    created_at,
    window_end,
    sent_at,
    min,
    mdn,
    cell_id,
    cell_type,
    cell_group_id,
    user_speed_threshold,
    user_control_speed,
    user_control_qos,
    prb_usage_threshold,
    prb_usage_predicted,
    timer,
    cron,
    dl_usage,
    ul_usage,
    user_grade,
    pgw_ip,
    pgw_region_code,
    is_send_success
FROM nwdaf.t_user_control_send_hist
WHERE 1=1
  ${MDN_CONDITION}
  ${CELL_GROUP_ID_CONDITION}
  AND window_end >= toDateTime('${START_TIME}')
  AND window_end < toDateTime('${END_TIME}')
FORMAT CSVWithNames
" | oc exec -i -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- bash -c 'clickhouse client --password ${CLICKHOUSE_ADMIN_PASSWORD}' > ${CSV}