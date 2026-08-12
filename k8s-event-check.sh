#!/bin/bash

echo ""
echo "[3] 네임스페이스별 K8S 이벤트 확인"
# 전역 요약 플래그: 모든 네임스페이스에서 Warning이 없으면 0, 하나라도 있으면 1
overall_warnings_found=0
TMP_REPORT=$(mktemp)
for ns in nwdaf kubeflow istio-system strimzi-kafka infra-datastore cert-manager auth infra-monitor metallb-system gpu-operator; do
    # collect one-line summary per namespace into TMP_REPORT

    # 간단 모드: Normal과 transient 이벤트는 무시하고, 나머지가 있으면 Warning으로 판단
    events_filtered=$(oc get event -n "$ns" 2>&1 | grep -v -E '^$' | grep -v -E '\bNormal\b' | grep -v -E '\btransient\b' || true)

    if echo "$events_filtered" | grep -q "No resources found" || [[ -z "$(echo "$events_filtered" | tr -d '[:space:]')" ]]; then
        printf "%-15s %-10s %s\n" "$ns" "[OK]" "이벤트 없음" >> "$TMP_REPORT"
        : > /tmp/event_${ns}_last24h.txt
        continue
    fi

    # 경고성 이벤트가 존재하면 임시 파일에 저장하고 플래그 설정
    echo "$events_filtered" > /tmp/event_${ns}_last24h.txt
    warnings_found=1
    overall_warnings_found=1

    # 로그 전체 출력 대신 건수만 출력
    warn_count=$(echo "$events_filtered" | sed '/^\s*$/d' | wc -l | tr -d ' ')
    if [[ $warn_count -gt 0 ]]; then
        printf "%-15s %-10s %s\n" "$ns" "[WARNING]" "${warn_count}건" >> "$TMP_REPORT"
    else
        printf "%-15s %-10s %s\n" "$ns" "[OK]" "이벤트 없음" >> "$TMP_REPORT"
    fi
done

# 전체 네임스페이스 요약 출력 (먼저)
if [[ $overall_warnings_found -eq 0 ]]; then
    echo "=> 전체 네임스페이스에서 K8S 이벤트 특이사항이 없습니다. [OK]"
else
    echo "=> 일부 네임스페이스에서 Warning 이벤트가 존재합니다. [WARNING]"
fi

# 그 다음에 네임스페이스별 상세 출력 (깔끔한 표 형식)
printf "\n"
printf "%-15s %-10s %s\n" "NAMESPACE" "STATUS" "DETAILS"
printf "%s\n" "---------------------------------------------------------"
cat "$TMP_REPORT"
rm -f "$TMP_REPORT"