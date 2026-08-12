#!/usr/bin/env bash
set -euo pipefail

# Kubernetes target
NAMESPACE="nwdaf"
POD="clickhouse-shard0-0"
CONTAINER="clickhouse"

# ClickHouse target
DB="ai"
TABLE="cell_usage_infer"
TS_COL="window_end"

# Export date input. END_TIME is fixed to the next day and is exclusive.
INPUT_DATE=""
EXPORT_DATE=""
EXPORT_DATE_KEY=""
START_TIME=""
END_TIME=""

# Query options
SELECT_EXPR="*"
EXTRA_WHERE="1"
COMPRESSOR="auto"
COMPRESS_SUFFIX=""
COMPRESS_LABEL=""

EXPORT_NAME=""

CH_CLIENT="clickhouse client --password \"\${CLICKHOUSE_ADMIN_PASSWORD}\""

usage() {
  cat <<EOF
Usage:
  $0 YYMMDD [options]

Example:
  $0 251020 --db nwdaf --table stat_cell_usage --ts-col window_end

Options:
  --namespace NAME       Kubernetes namespace. Default: ${NAMESPACE}
  --pod NAME             Kubernetes pod. Default: ${POD}
  --container NAME       Container name. Empty means kubectl/oc default.
  --db NAME              ClickHouse database.
  --table NAME           ClickHouse table.
  --ts-col NAME          Timestamp column used for range filtering.
  --select EXPR          SELECT expression. Default: *
  --where EXPR           Extra WHERE condition. Default: 1
  --compressor NAME      Compression tool: auto, zstd, pigz, gzip, xz, none. Default: auto
  --export-name NAME     Output file name group. Default: <db>_<table>.
  -h, --help             Show this help.
EOF
}

need_cmd() {
  local cmd="$1"

  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command not found in PATH: ${cmd}" >&2
    exit 1
  fi
}

choose_kube_cmd() {
  if command -v oc >/dev/null 2>&1; then
    KUBE_CMD=oc
  elif command -v kubectl >/dev/null 2>&1; then
    KUBE_CMD=kubectl
  else
    echo "ERROR: neither 'oc' nor 'kubectl' found in PATH." >&2
    exit 1
  fi
}

choose_date_cmd() {
  if command -v gdate >/dev/null 2>&1; then
    DATE_CMD=gdate
  else
    DATE_CMD=date
  fi

  if ! "${DATE_CMD}" -d "2000-01-01" >/dev/null 2>&1; then
    echo "ERROR: '${DATE_CMD}' does not support '-d'. Install GNU date/coreutils or add gdate to PATH." >&2
    exit 1
  fi
}

choose_compressor() {
  case "${COMPRESSOR}" in
    auto)
      if command -v zstd >/dev/null 2>&1; then
        COMPRESSOR=zstd
      elif command -v pigz >/dev/null 2>&1; then
        COMPRESSOR=pigz
      elif command -v gzip >/dev/null 2>&1; then
        COMPRESSOR=gzip
      elif command -v xz >/dev/null 2>&1; then
        COMPRESSOR=xz
      else
        COMPRESSOR=none
      fi
      ;;
    zstd|pigz|gzip|xz)
      need_cmd "${COMPRESSOR}"
      ;;
    none)
      ;;
    *)
      echo "ERROR: unsupported compressor: ${COMPRESSOR}" >&2
      echo "       supported: auto, zstd, pigz, gzip, xz, none" >&2
      exit 1
      ;;
  esac

  case "${COMPRESSOR}" in
    zstd) COMPRESS_SUFFIX=".zst"; COMPRESS_LABEL="zstd" ;;
    pigz) COMPRESS_SUFFIX=".gz"; COMPRESS_LABEL="pigz/gzip" ;;
    gzip) COMPRESS_SUFFIX=".gz"; COMPRESS_LABEL="gzip" ;;
    xz) COMPRESS_SUFFIX=".xz"; COMPRESS_LABEL="xz" ;;
    none) COMPRESS_SUFFIX=""; COMPRESS_LABEL="none" ;;
  esac
}

check_remote_tools() {
  if "${KUBE_EXEC[@]}" sh -c 'command -v bash >/dev/null 2>&1 && command -v clickhouse >/dev/null 2>&1' >/dev/null 2>&1; then
    echo "[check] remote tools ok: bash, clickhouse"
  else
    echo "ERROR: remote container must have 'bash' and 'clickhouse' in PATH." >&2
    exit 1
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --pod) POD="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --db) DB="$2"; shift 2 ;;
    --table) TABLE="$2"; shift 2 ;;
    --ts-col) TS_COL="$2"; shift 2 ;;
    --select) SELECT_EXPR="$2"; shift 2 ;;
    --where) EXTRA_WHERE="$2"; shift 2 ;;
    --compressor) COMPRESSOR="$2"; shift 2 ;;
    --export-name) EXPORT_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [ -n "${INPUT_DATE}" ]; then
        echo "ERROR: only one YYMMDD input is allowed." >&2
        usage
        exit 1
      fi
      INPUT_DATE="$1"
      shift
      ;;
  esac
done

choose_kube_cmd
choose_date_cmd
choose_compressor
need_cmd awk
need_cmd basename
need_cmd cat
need_cmd ls

if [[ ! "${INPUT_DATE}" =~ ^[0-9]{6}$ ]]; then
  echo "ERROR: date input must be YYMMDD format, for example 251020." >&2
  usage
  exit 1
fi

EXPORT_DATE="20${INPUT_DATE:0:2}-${INPUT_DATE:2:2}-${INPUT_DATE:4:2}"
EXPORT_DATE_KEY="${EXPORT_DATE//-/}"

if ! "${DATE_CMD}" -d "${EXPORT_DATE}" >/dev/null 2>&1; then
  echo "ERROR: invalid date: ${EXPORT_DATE}" >&2
  exit 1
fi

START_TIME="${EXPORT_DATE} 00:00:00"
END_TIME="$("${DATE_CMD}" -d "${EXPORT_DATE} +1 day" "+%Y-%m-%d 00:00:00")"
START_EPOCH="$("${DATE_CMD}" -d "${START_TIME}" +%s)"
END_EPOCH="$("${DATE_CMD}" -d "${END_TIME}" +%s)"

if [ "${START_EPOCH}" -ge "${END_EPOCH}" ]; then
  echo "ERROR: calculated export range is invalid." >&2
  exit 1
fi

if [ -z "${EXPORT_NAME}" ]; then
  EXPORT_NAME="${DB}_${TABLE}"
fi

if [[ "${EXPORT_NAME}" == */* ]]; then
  echo "ERROR: --export-name must be a file name group, not a path: ${EXPORT_NAME}" >&2
  exit 1
fi

KUBE_EXEC=("${KUBE_CMD}" exec -n "${NAMESPACE}" "${POD}")
if [ -n "${CONTAINER}" ]; then
  KUBE_EXEC+=(-c "${CONTAINER}")
fi
KUBE_EXEC+=(--)

if "${KUBE_EXEC[@]}" ls / >/dev/null 2>&1; then
  echo "[check] Kubernetes exec access ok: ${NAMESPACE}/${POD}"
else
  echo "ERROR: cannot exec into ${NAMESPACE}/${POD}." >&2
  exit 1
fi
check_remote_tools
echo "[check] compressor: ${COMPRESS_LABEL}"

FILE_PREFIX="${EXPORT_DATE_KEY}__${EXPORT_NAME}"
META_FILE="${FILE_PREFIX}__meta.tsv"
META_TXT_FILE="${FILE_PREFIX}__meta.txt"
echo -e "file\tstart_time\tend_time\trow_count\tmin_ts\tmax_ts" > "${META_FILE}"

run_export() {
  local query="$1"
  local out_file="$2"

  case "${COMPRESSOR}" in
    zstd)
      run_ch_query "${query}" | zstd -T0 -o "${out_file}"
      ;;
    pigz)
      run_ch_query "${query}" | pigz -c > "${out_file}"
      ;;
    gzip)
      run_ch_query "${query}" | gzip -c > "${out_file}"
      ;;
    xz)
      run_ch_query "${query}" | xz -T0 -c > "${out_file}"
      ;;
    none)
      run_ch_query "${query}" > "${out_file}"
      ;;
  esac
}

run_ch_query() {
  local query="$1"

  "${KUBE_EXEC[@]}" bash -c "${CH_CLIENT} --query=\"\$1\"" _ "${query}"
}

WHERE="${TS_COL} >= toDateTime('${START_TIME}') AND ${TS_COL} < toDateTime('${END_TIME}') AND (${EXTRA_WHERE})"
OUT_FILE="${FILE_PREFIX}__data.native${COMPRESS_SUFFIX}"

echo "[metadata] ${START_TIME} ~ ${END_TIME}"

META_ROW="$(
  run_ch_query "
      SELECT
        count() AS row_count,
        min(${TS_COL}) AS min_ts,
        max(${TS_COL}) AS max_ts
      FROM ${DB}.${TABLE}
      WHERE ${WHERE}
      FORMAT TSV
    "
)"

ROW_COUNT="$(echo "${META_ROW}" | awk -F'\t' '{print $1}')"

if [ "${ROW_COUNT}" = "0" ]; then
  echo "[skip] ${INPUT_DATE}: row_count=0"
  echo -e "$(basename "${OUT_FILE}")\t${START_TIME}\t${END_TIME}\t${META_ROW}" >> "${META_FILE}"
else
  echo "[export] ${INPUT_DATE}, rows=${ROW_COUNT}"

  run_export "
    SELECT ${SELECT_EXPR}
    FROM ${DB}.${TABLE}
    WHERE ${WHERE}
    FORMAT Native
  " "${OUT_FILE}"

  echo -e "$(basename "${OUT_FILE}")\t${START_TIME}\t${END_TIME}\t${META_ROW}" >> "${META_FILE}"
fi

cat > "${META_TXT_FILE}" <<EOF
db=${DB}
table=${TABLE}
export_name=${EXPORT_NAME}
ts_col=${TS_COL}
input_date=${INPUT_DATE}
start_time=${START_TIME}
end_time=${END_TIME}
select_expr=${SELECT_EXPR}
extra_where=${EXTRA_WHERE}
EOF

echo
echo "done: $(pwd)"
if [ -f "${OUT_FILE}" ]; then
  ls -lh "${OUT_FILE}"
fi
ls -lh "${META_FILE}" "${META_TXT_FILE}"
echo
cat "${META_FILE}"
