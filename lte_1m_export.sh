#!/usr/bin/env bash

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<EOF
Usage:
  DATE=YYMMDD $0
  export DATE=YYMMDD && $0

Example:
  DATE=260621 ./lte_1m_export.sh

Description:
  Exports ai.cell_usage_infer (LTE, 1m) in ${NUM_SHARDS:-8} shards via export_cell_usage.sh.
  The DATE environment variable must be set in YYMMDD format before running.
EOF
  exit 0
fi

# 1분 테이블 lte
NUM_SHARDS=8
for i in $(seq 1 $NUM_SHARDS)
do
  SHARD_NUM=$((i-1))
  ./export_cell_usage.sh "${DATE}" --export-name "lte_1m_shard${SHARD_NUM}" --select "enb_cell_id,freq_type,window_end,total_user_count,heavy_user_count,medium2_user_count,medium1_user_count,light_user_count,total_user_usage,heavy_user_usage,medium2_user_usage,medium1_user_usage,light_user_usage,duration,iot_user_count,iot_user_usage,bps_mean,bps_std,bps_max,top_1_user_usage_share,fraction_for_20pct_usage,fraction_for_50pct_usage,fraction_for_80pct_usage" --where "modulo(cityHash64(enb_cell_id), ${NUM_SHARDS}) = ${SHARD_NUM} AND cell_type='lte' AND total_user_count IS NOT NULL"
done
