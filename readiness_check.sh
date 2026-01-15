#!/bin/bash

if [ $# -eq 0 ]; then
    echo "사용법: $0 <네임스페이스>"
    exit 1
fi

NAMESPACE=$1

echo "NAMESPACE | POD | CONTAINER | PROBE TYPE | PROBE CONFIG"
echo "-----------------------------------------------------------"

# 네임스페이스의 모든 Pod 조회 후 JSON 출력
oc get pod -n "$NAMESPACE" -o json | jq -r '
    .items[] | 
    .metadata.name as $pod_name | 
    .spec.containers[] | 
    .name as $container_name | 
    (if .readinessProbe then 
        [ $pod_name, $container_name, "readinessProbe", (.readinessProbe | tostring) ] | @tsv 
    else empty end),
    (if .livenessProbe then 
        [ $pod_name, $container_name, "livenessProbe", (.livenessProbe | tostring) ] | @tsv 
    else empty end)
' | awk -v ns="$NAMESPACE" '{print ns, "|", $1, "|", $2, "|", $3, "|", $4}'