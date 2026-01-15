#!/bin/bash

# 조회할 네임스페이스 목록
namespaces=("nwdaf" "strimzi-kafka" "kubeflow" "istio-system" "cert-manager" "infra-monitor" "infra-log" "infra-datastore" "infra-deploy" "nwdaf-webhook" "nwdaf-local-path" "auth" "oauth2-proxy" "metallb-system" "kubeflow-user-example-com")

# 워커 노드 목록
nodes=("snsu-5g21b-nwdaf-wk01.ocp21.skt.local" "snsu-5g21b-nwdaf-wk02.ocp21.skt.local" "snsu-5g21b-nwdaf-wk03.ocp21.skt.local")

# 노드명을 간단하게 출력하기 위한 매핑
declare -A node_name_map
node_name_map["snsu-5g21b-nwdaf-wk01.ocp21.skt.local"]="worker-1"
node_name_map["snsu-5g21b-nwdaf-wk02.ocp21.skt.local"]="worker-2"
node_name_map["snsu-5g21b-nwdaf-wk03.ocp21.skt.local"]="worker-3"

# 긴 네임스페이스 이름을 20자로 제한하는 함수
truncate_namespace() {
    local ns="$1"
    local max_length=20
    if [ ${#ns} -gt $max_length ]; then
        echo "${ns:0:$((max_length-3))}..."
    else
        echo "$ns"
    fi
}

echo
echo "Pod 개수 표시 형식: A / B"
echo "  A: Running 또는 Completed 상태의 Pod 개수"
echo "  B: 해당 노드에서 실행 중인 전체 Pod 개수"
echo

# 테이블 헤더 출력
printf "%-20s %-15s %-15s %-15s\n" "Namespace" "worker-1" "worker-2" "worker-3"
echo "------------------------------------------------------------------------------------------"

# 네임스페이스별로 Pod 개수 카운트
for namespace in "${namespaces[@]}"; do
    truncated_ns=$(truncate_namespace "$namespace")
    row=$(printf "%-20s" "$truncated_ns")

    for node in "${nodes[@]}"; do
        # 노드별 전체 Pod 개수
        total_pods=$(oc get pods -n "$namespace" -o wide --no-headers | awk -v node="$node" '{if ($7 == node) count++} END {print count+0}')
        
        # 노드별 Running 또는 Completed 상태의 Pod 개수
        running_completed_pods=$(oc get pods -n "$namespace" -o wide --no-headers | awk -v node="$node" '{if ($7 == node && ($3 == "Running" || $3 == "Completed")) count++} END {print count+0}')
        
        # 결과를 "X/Y" 형식으로 저장
        result="$running_completed_pods/$total_pods"
        row="$row $(printf "%-15s" "$result")"
    done

    echo "$row"
done