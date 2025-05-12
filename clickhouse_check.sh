#!/bin/bash

NAMESPACE="nwdaf"
CLICKHOUSE_PORT=8123  # 기본 HTTP 포트 (MySQL 포트는 9000)
LABEL_SELECTOR_ALL="app.kubernetes.io/instance=clickhouse"
LABEL_SELECTOR="app.kubernetes.io/name=clickhouse"
CLICKHOUSE_USER="default"
CLICKHOUSE_PASSWORD=$(oc get secret clickhouse -n $NAMESPACE -o jsonpath='{.data.admin-password}' | base64 -d)

CLICKHOUSE_POD=$(oc get pods -n $NAMESPACE -l $LABEL_SELECTOR -o jsonpath='{.items[0].metadata.name}')

CHECK_QUERY="
SELECT 
    hostName(), 
    uptime(), 
    version() 
FROM system.build_options 
FORMAT TSVWithNames
"

CLUSTER_QUERY="
SELECT 
    * 
FROM system.clusters 
FORMAT TSVWithNames
"

REPLICAS_QUERY="
SELECT 
    database, 
    table, 
    is_leader, 
    total_replicas 
FROM system.replicas 
FORMAT TSVWithNames
"

MUTATIONS_QUERY="
SELECT 
    database, 
    table, 
    command, 
    is_done 
FROM system.mutations 
WHERE is_done=0 
FORMAT TSVWithNames
"

DISK_USAGE_QUERY="
SELECT 
    name AS Name, 
    path AS Path, 
    formatReadableSize(free_space) AS Free, 
    formatReadableSize(total_space) AS Total, 
    1 - free_space/total_space AS Used 
FROM system.disks
"

# ClickHouse Pod 상태 확인 함수
check_pod_status() {
    echo "===== ClickHouse Pod 상태 확인 ====="
    oc get pods -n $NAMESPACE -l "$LABEL_SELECTOR_ALL" -o wide
}

# ClickHouse 서비스 포트 확인 함수
check_service_port() {
    echo ""
    echo "===== ClickHouse 서비스 포트 확인 (포트: $CLICKHOUSE_PORT) ====="
    oc exec -n $NAMESPACE $CLICKHOUSE_POD -q -- bash -c "netstat -tulnp | grep $CLICKHOUSE_PORT" || echo "포트 $CLICKHOUSE_PORT 가 열려 있지 않음"
}

# ClickHouse 노드 상태 확인 함수
check_node_status() {
    echo ""
    echo "===== ClickHouse 노드 상태 확인 ====="
    oc exec -n $NAMESPACE $CLICKHOUSE_POD -q -- clickhouse-client --user $CLICKHOUSE_USER --password $CLICKHOUSE_PASSWORD --query "$CHECK_QUERY"
}

# ClickHouse 클러스터 노드 정보 확인 함수
check_cluster_info() {
    echo ""
    echo "===== ClickHouse 클러스터 노드 정보 확인 ====="
    oc exec -n $NAMESPACE $CLICKHOUSE_POD -q -- clickhouse-client --user $CLICKHOUSE_USER --password $CLICKHOUSE_PASSWORD --query "$CLUSTER_QUERY"
}

# ClickHouse 복제 상태 확인 함수
check_replica_status() {
    echo ""
    echo "===== ClickHouse 복제 상태 확인 ====="
    oc exec -n $NAMESPACE $CLICKHOUSE_POD -q -- clickhouse-client --user $CLICKHOUSE_USER --password $CLICKHOUSE_PASSWORD --query "$REPLICAS_QUERY" | column -t
}

# ClickHouse 디스크 사용량 확인 함수
check_disk_usage() {
    echo ""
    echo "===== ClickHouse 디스크 사용량 확인 ====="
    oc exec -n $NAMESPACE $CLICKHOUSE_POD -q -- clickhouse-client --user $CLICKHOUSE_USER --password $CLICKHOUSE_PASSWORD --query "$DISK_USAGE_QUERY" || echo "디스크 사용량 정보를 가져오지 못함"
}

# ClickHouse 진행 중인 Mutations 확인 함수
check_mutations() {
    echo ""
    echo "===== ClickHouse 진행 중인 Mutations 확인 ====="
    oc exec -n $NAMESPACE $CLICKHOUSE_POD -q -- clickhouse-client --user $CLICKHOUSE_USER --password $CLICKHOUSE_PASSWORD --query "$MUTATIONS_QUERY"
}

# 메인 실행 함수
main() {
    check_pod_status
    check_service_port
    check_node_status
    check_cluster_info
    check_replica_status
    check_disk_usage
    check_mutations
}

# 스크립트 실행
main



