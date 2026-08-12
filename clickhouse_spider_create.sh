#!/bin/bash

# ============================================================
# ClickHouse spider 계정 생성 및 권한 설정 스크립트
# 대상 파드: clickhouse-shard0-0, clickhouse-shard0-1, clickhouse-shard0-2
# ============================================================

set -euo pipefail

NAMESPACE="nwdaf"
PODS=("clickhouse-shard0-0" "clickhouse-shard0-1" "clickhouse-shard0-2")
TIMEOUT=60

# 결과 저장 배열
declare -A POD_RESULTS
declare -A POD_GRANTS
declare -A POD_MEMORY_SETTINGS
FAILURE_COUNT=0

# ============================================================
# 사전 조건 확인: oc whoami
# ============================================================
CURRENT_USER=$(oc whoami 2>/dev/null || echo "")

if [[ "${CURRENT_USER}" != "nwdaf-admin" ]]; then
  echo "❌ [ABORT] 현재 로그인 계정: '${CURRENT_USER}'"
  echo "   'nwdaf-admin' 계정으로 로그인 후 다시 실행하세요."
  exit 1
fi

echo "✅ 현재 로그인 계정: ${CURRENT_USER}"
echo ""

# ============================================================
# 파드 상태 사전 검증
# ============================================================
echo "🔍 파드 상태 확인 중..."
MISSING_PODS=()
for POD in "${PODS[@]}"; do
  POD_STATUS=$(oc get pod -n "${NAMESPACE}" "${POD}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  
  if [[ "${POD_STATUS}" == "NotFound" ]]; then
    echo "❌ [${POD}] 파드가 존재하지 않습니다."
    MISSING_PODS+=("${POD}")
  elif [[ "${POD_STATUS}" != "Running" ]]; then
    echo "⚠️  [${POD}] 파드 상태: ${POD_STATUS} (Running이 아님)"
    MISSING_PODS+=("${POD}")
  else
    echo "✅ [${POD}] 상태: ${POD_STATUS}"
  fi
done

if [[ ${#MISSING_PODS[@]} -gt 0 ]]; then
  echo ""
  echo "❌ [ABORT] 일부 파드가 준비되지 않았습니다: ${MISSING_PODS[*]}"
  exit 1
fi

echo "✅ 모든 파드가 Running 상태입니다."
echo ""

# ============================================================
# SQL 명령 생성 함수
# ============================================================
build_sql() {
  cat <<'EOF'
-- spider 계정 생성
CREATE USER IF NOT EXISTS spider IDENTIFIED BY 'spider!234';
ALTER USER spider SETTINGS max_memory_usage = 4000000000, max_memory_usage_for_user = 8000000000;

-- 계정 생성 확인
SELECT name, auth_type FROM system.users WHERE name = 'spider';
SHOW CREATE USER spider;

-- 권한 설정
GRANT SELECT ON nwdaf.conn_pgsql_mv_t_cell_5g_all TO spider;
GRANT SELECT ON nwdaf.conn_pgsql_mv_t_cell_lte_all TO spider;
GRANT SELECT ON nwdaf.conn_pgsql_t_config_common TO spider;
GRANT SELECT ON nwdaf.conn_pgsql_t_config_user_grade TO spider;
GRANT SELECT ON nwdaf.stat_cell_usage TO spider;
GRANT SELECT ON nwdaf.stat_ipmdn_recv TO spider;
GRANT SELECT ON nwdaf.t_4g_cell_prb_5m TO spider;
GRANT SELECT ON nwdaf.t_5g_cell_prb_15m TO spider;
GRANT SELECT ON nwdaf.t_cell_control_config TO spider;
GRANT SELECT ON nwdaf.t_cell_control_hist TO spider;
GRANT SELECT ON nwdaf.t_cell_prb_usage_predicted TO spider;
GRANT SELECT ON nwdaf.t_cmsweb_hist TO spider;
GRANT SELECT ON nwdaf.t_model_evaluation_hist TO spider;
GRANT SELECT ON nwdaf.t_user_control_send_hist TO spider;
GRANT SELECT ON nwdaf.t_window_mdn_cell TO spider;
GRANT SELECT ON ai.cell_usage_hist_5m TO spider;
GRANT SELECT ON ai.model_train_hist TO spider;
GRANT SELECT ON ai.t_cell_prb_usage_predicted TO spider;

-- 권한 확인
SHOW GRANTS FOR spider;
EOF
}

# ============================================================
# 파드별 작업 실행
# ============================================================
for POD in "${PODS[@]}"; do
  echo "============================================================"
  echo "🚀 [${POD}] 작업 시작"
  echo "============================================================"

  SQL=$(build_sql)
  
  # SQL을 파드 내부 bash로 전달하여 실행
  OUTPUT=$(timeout "${TIMEOUT}" oc exec -i -n "${NAMESPACE}" "${POD}" -- bash -c \
    'clickhouse-client --password="${CLICKHOUSE_ADMIN_PASSWORD}" --multiquery --multiline' \
    2>&1 <<< "${SQL}") && EXIT_CODE=0 || EXIT_CODE=$?

  echo "${OUTPUT}"
  echo ""

  if [[ ${EXIT_CODE} -eq 0 ]]; then
    # 계정 존재 여부 및 권한 수 파싱
    # "Defaulted container" 메시지를 제거한 후 파싱
    CLEAN_OUTPUT=$(echo "${OUTPUT}" | grep -v "Defaulted container")
    USER_LINE=$(echo "${CLEAN_OUTPUT}" | grep -i "spider" | grep -v "GRANT" | grep -v "CREATE" | head -1 || echo "")
    GRANT_COUNT=$(echo "${CLEAN_OUTPUT}" | grep -c "GRANT SELECT" || echo "0")
    
    # SHOW GRANTS 결과 추출 (GRANT로 시작하는 라인들)
    GRANT_RESULTS=$(echo "${CLEAN_OUTPUT}" | grep "^GRANT" | sort)
    POD_GRANTS["${POD}"]="${GRANT_RESULTS}"
    
    # 메모리 설정값 추출 (SHOW CREATE USER 결과에서)
    MEMORY_SETTINGS=$(echo "${CLEAN_OUTPUT}" | grep "SETTINGS" | grep -oP 'max_memory_usage(_for_user)? = \d+' | tr '\n' ', ' | sed 's/,$//' || echo "N/A")
    POD_MEMORY_SETTINGS["${POD}"]="${MEMORY_SETTINGS}"

    if [[ -n "${USER_LINE}" ]]; then
      POD_RESULTS["${POD}"]="✅ 성공 | 사용자 확인: ${USER_LINE} | GRANT 수: ${GRANT_COUNT}"
      echo "✅ [${POD}] 작업 성공 (GRANT 수: ${GRANT_COUNT})"
      echo "   메모리 설정: ${MEMORY_SETTINGS}"
    else
      POD_RESULTS["${POD}"]="⚠️  실행됐으나 사용자 조회 결과 없음 (출력 확인 필요) | GRANT 수: ${GRANT_COUNT}"
      echo "⚠️  [${POD}] 경고: 사용자 조회 결과 없음"
      ((FAILURE_COUNT++))
    fi
  else
    POD_RESULTS["${POD}"]="❌ 실패 (exit code: ${EXIT_CODE})"
    echo "❌ [${POD}] 작업 실패 (exit code: ${EXIT_CODE})"
    
    # 에러 메시지 추출 (stderr 또는 error 키워드 포함 라인)
    ERROR_LINES=$(echo "${OUTPUT}" | grep -i "error" | head -3 || echo "")
    if [[ -n "${ERROR_LINES}" ]]; then
      echo "   주요 에러:"
      echo "${ERROR_LINES}" | sed 's/^/   > /'
    fi
    ((FAILURE_COUNT++))
  fi
  echo ""

done

# ============================================================
# 실행 결과 요약
# ============================================================
echo ""
echo "============================================================"
echo "📋 파드별 실행 결과 요약"
echo "============================================================"
printf "%-30s | %s\n" "파드명" "결과"
printf "%-30s-+-%s\n" "------------------------------" "--------------------------------------------"
for POD in "${PODS[@]}"; do
  printf "%-30s | %s\n" "${POD}" "${POD_RESULTS[${POD}]}"
done
echo "============================================================"

# ============================================================
# 메모리 설정 확인
# ============================================================
echo ""
echo "============================================================"
echo "💾 메모리 설정값 확인"
echo "============================================================"

MEMORY_CONSISTENT=true
REFERENCE_MEMORY=""
for POD in "${PODS[@]}"; do
  MEMORY="${POD_MEMORY_SETTINGS[${POD}]:-N/A}"
  echo "[${POD}]: ${MEMORY}"
  
  if [[ -z "${REFERENCE_MEMORY}" && "${MEMORY}" != "N/A" ]]; then
    REFERENCE_MEMORY="${MEMORY}"
  elif [[ "${MEMORY}" != "N/A" && "${MEMORY}" != "${REFERENCE_MEMORY}" ]]; then
    MEMORY_CONSISTENT=false
  fi
done

if [[ "${MEMORY_CONSISTENT}" == true && -n "${REFERENCE_MEMORY}" ]]; then
  echo ""
  echo "✅ 모든 파드의 메모리 설정이 동일합니다."
else
  echo ""
  echo "⚠️  파드 간 메모리 설정이 다릅니다!"
fi

# ============================================================
# GRANT 권한 비교
# ============================================================
echo ""
echo "============================================================"
echo "🔍 파드 간 GRANT 권한 일치성 검증"
echo "============================================================"

# 성공한 파드들의 GRANT 결과 비교
SUCCESSFUL_PODS=()
for POD in "${PODS[@]}"; do
  if [[ -n "${POD_GRANTS[${POD}]:-}" ]]; then
    SUCCESSFUL_PODS+=("${POD}")
  fi
done

if [[ ${#SUCCESSFUL_PODS[@]} -eq 0 ]]; then
  echo "⚠️  비교할 GRANT 결과가 없습니다 (모든 파드에서 실패)"
elif [[ ${#SUCCESSFUL_PODS[@]} -eq 1 ]]; then
  echo "ℹ️  GRANT 결과가 있는 파드: ${SUCCESSFUL_PODS[0]}"
  echo ""
  echo "GRANT 권한 목록:"
  echo "${POD_GRANTS[${SUCCESSFUL_PODS[0]}]}"
else
  # 첫 번째 파드를 기준으로 비교
  REFERENCE_POD="${SUCCESSFUL_PODS[0]}"
  REFERENCE_GRANTS="${POD_GRANTS[${REFERENCE_POD}]}"
  ALL_IDENTICAL=true
  
  for POD in "${SUCCESSFUL_PODS[@]:1}"; do
    if [[ "${POD_GRANTS[${POD}]}" != "${REFERENCE_GRANTS}" ]]; then
      ALL_IDENTICAL=false
      break
    fi
  done
  
  if [[ "${ALL_IDENTICAL}" == true ]]; then
    echo "✅ 모든 파드의 GRANT 권한이 동일합니다."
    echo ""
    echo "GRANT 권한 목록 (총 ${#SUCCESSFUL_PODS[@]}개 파드 공통):"
    echo "${REFERENCE_GRANTS}"
  else
    echo "⚠️  파드 간 GRANT 권한이 다릅니다!"
    echo ""
    for POD in "${SUCCESSFUL_PODS[@]}"; do
      echo "--- [${POD}] ---"
      echo "${POD_GRANTS[${POD}]}"
      echo ""
    done
  fi
fi

echo "============================================================"

if [[ ${FAILURE_COUNT} -eq 0 ]]; then
  echo "✅ 모든 파드 작업 완료 - 성공"
  exit 0
else
  echo "❌ 작업 완료 - ${FAILURE_COUNT}개 파드에서 실패 발생"
  exit 1
fi