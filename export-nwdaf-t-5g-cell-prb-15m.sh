#!/bin/bash
## ./export-nwdaf-t-5g-cell-prb-15m.sh [YYMMDDHH]

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
if [[ ! "$INPUT" =~ ^[0-9]{8}$ ]]; then
  echo "❌ 형식 오류: YYMMDDHH 형태(예: 26031703)로 입력하세요."
  exit 1
fi

DATE="20${INPUT:0:2}-${INPUT:2:2}-${INPUT:4:2}"
HOUR="${INPUT:6:2}"

# 시간 범위 확인
if [ $((10#$HOUR)) -lt 0 ] || [ $((10#$HOUR)) -gt 23 ]; then
  echo "❌ 유효하지 않은 시간입니다: ${HOUR}시 (00-23 범위)"
  exit 1
fi

if ! date -d "$DATE" >/dev/null 2>&1; then
  echo "❌ 유효하지 않은 날짜입니다: $DATE"
  exit 1
fi

NEXT_HOUR=$(printf "%02d" $((10#$HOUR + 1)))

# 23시의 경우 다음날 00시로 설정
if [ "$HOUR" == "23" ]; then
  END_TIME=$(date -d "$DATE +1 day" +"%Y-%m-%d 00:00:00")
else
  END_TIME="${DATE} ${NEXT_HOUR}:00:00"
fi

START_TIME="${DATE} ${HOUR}:00:00"
CSV="t_5g_cell_prb_15m_${INPUT}.csv"

echo "✅ 쿼리 > ${CSV} (${HOUR}:00 ~ ${NEXT_HOUR}:00)"

echo "WITH
    '${START_TIME}' AS start_time,
    '${END_TIME}' AS end_time
SELECT
    std_dhm,
    occr_dth,
    perf_dat_id,
    mgmt_eqp_id,
    ver_ctt,
    ems_id,
    eqp_knd_nm,
    eqp_vend_nm,
    eqp_nm,
    eqp_id,
    eqp_origin_nm,
    eqp_ems_nm,
    eqp_op_als_nm,
    eqp_rep_nm,
    srvc_net_cd,
    srvc_net_nm,
    ems_eqp_id,
    ems_eqp_nm,
    eqp_fst_mapp_id,
    eqp_scnd_mapp_id,
    eqp_mapp_nm,
    eqp_fw_ver_val,
    jrdt_hdofc_org_id,
    jrdt_hdofc_org_nm,
    op_hdofc_org_id,
    op_hdofc_org_nm,
    jrdt_team_org_id,
    jrdt_team_org_nm,
    op_team_org_id,
    op_team_org_nm,
    eqp_own_bizr_cd,
    lnkg_systm_div_cd,
    mtso_id,
    mtso_nm,
    sido_cd,
    sido_nm,
    sgg_cd,
    sgg_nm,
    eqp_dcl_cd,
    mme_grp_id,
    shr_net_cell_yn,
    cell_id,
    pci,
    frequency,
    etl_work_dtmt,
    dl_prb_usage,
    ul_prb_usage,
    event_date
FROM nwdaf.t_5g_cell_prb_15m
PREWHERE
    event_date >= start_time AND
    event_date < end_time
ORDER BY event_date, cell_id
FORMAT CSVWithNames" | ${CMD} exec -i -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- bash -c 'clickhouse client --password ${CLICKHOUSE_ADMIN_PASSWORD}' > ${CSV}

echo "✅ xz 압축 > ${CSV}"
xz -T 4 -2 -kv ${CSV}

echo "✅ 완료: ${CSV}.xz"