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

CSV="hu_stat_latest10m.csv"

echo "✅ 쿼리 > ${CSV}"

echo "
WITH
    toStartOfMinute(now()) - INTERVAL 15 MINUTE AS start_time,
    start_time + INTERVAL 10 MINUTE AS end_time,
    hu AS (
        SELECT
            mdn,
            window_end,
            sumMerge(sum_duration) as sum_duration,
            8 * sumMerge(sum_dl_usage) / sum_duration as dl_bps,
            if(sum_duration > 0
            AND dl_bps > anyMerge(heavy_threshold), 1, 0) as is_heavy_user
        FROM nwdaf.t_window_mdn_cell
        WHERE window_end > start_time AND window_end <= end_time
        GROUP BY mdn, window_end
    ),
    hu_mdn AS (
        SELECT mdn
        FROM hu
        GROUP BY mdn HAVING sum(is_heavy_user) > 0
    )
SELECT
    mdn,
    cell_id,
    cell_type,
    window_start,
    window_end,
    sumMerge(sum_dl_usage) as sum_dl_usage,
    sumMerge(sum_ul_usage) as sum_ul_usage,
    sumMerge(sum_duration) as sum_duration
FROM nwdaf.t_window_mdn_cell
WHERE
    window_end > start_time
    AND window_end <= end_time
    AND mdn IN hu_mdn
GROUP BY mdn, cell_id, cell_type, window_start, window_end
ORDER BY mdn, window_end
FORMAT CSVWithNames;" | ${CMD} exec -i -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- bash -c 'clickhouse client --password ${CLICKHOUSE_ADMIN_PASSWORD}' > ${CSV}

echo "✅ xz 압축"
xz -T 4 -2 -kv ${CSV}
 
