#!/bin/bash

# 조회할 네임스페이스 목록
namespaces=("nwdaf" "strimzi-kafka" "kubeflow" "istio-system" "knative-serving" "cert-manager" "infra-monitor" "argo-events" "infra-log" "infra-datastore" "infra-deploy" "nwdaf-webhook" "auth" "oauth2-proxy" "kubeflow-user-example-com")

# 워커 노드 목록
nodes=("bdtb-sa03a-nwdaf-wk01.ocp03.skt.local" "bdtb-sa03a-nwdaf-wk02.ocp03.skt.local" "bdtb-sa03a-nwdaf-wk03.ocp03.skt.local" "bdtb-sa03a-aisfm-wk01.ocp03.skt.local" "bdtb-sa03a-aisfm-gpuwk01.ocp03.skt.local")

# 노드명을 간단하게 출력하기 위한 매핑
declare -A node_name_map
node_name_map["bdtb-sa03a-nwdaf-wk01.ocp03.skt.local"]="worker-1"
node_name_map["bdtb-sa03a-nwdaf-wk02.ocp03.skt.local"]="worker-2"
node_name_map["bdtb-sa03a-nwdaf-wk03.ocp03.skt.local"]="worker-3"
node_name_map["bdtb-sa03a-aisfm-wk01.ocp03.skt.local"]="cnaps-1"
node_name_map["bdtb-sa03a-aisfm-gpuwk01.ocp03.skt.local"]="cnaps-2"

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
printf "%-20s %-15s %-15s %-15s %-15s %-15s\n" "Namespace" "worker-1" "worker-2" "worker-3" "cnaps-1" "cnaps-2"
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