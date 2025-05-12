#!/bin/bash

if [ $# -ne 1 ]; then
  echo "Usage: $0 <namespace>"
  exit 1
fi

NAMESPACE="$1"

# 출력 헤더 포함 후 정렬 출력
{
  echo -e "POD\tCONTAINER_TYPE\tCONTAINER\tREQUESTS_CPU\tREQUESTS_MEM\tLIMITS_CPU\tLIMITS_MEM"
  kubectl get pods -n "$NAMESPACE" -o json | jq -r '
    .items[] as $pod |
    (
      $pod.spec.containers[] | {
        pod: $pod.metadata.name,
        type: "container",
        name: .name,
        requests_cpu: (.resources.requests.cpu // "-"),
        requests_mem: (.resources.requests.memory // "-"),
        limits_cpu: (.resources.limits.cpu // "-"),
        limits_mem: (.resources.limits.memory // "-")
      }
    ),
    (
      ($pod.spec.initContainers // [])[] | {
        pod: $pod.metadata.name,
        type: "initContainer",
        name: .name,
        requests_cpu: (.resources.requests.cpu // "-"),
        requests_mem: (.resources.requests.memory // "-"),
        limits_cpu: (.resources.limits.cpu // "-"),
        limits_mem: (.resources.limits.memory // "-")
      }
    )
    | [.pod, .type, .name, .requests_cpu, .requests_mem, .limits_cpu, .limits_mem]
    | @tsv
  '
} | column -t -s $'\t'
