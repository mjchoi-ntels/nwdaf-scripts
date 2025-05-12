#!/bin/bash

NAMESPACE="strimzi-kafka"
BOOTSTRAP_SERVER="kafka-kafka-bootstrap.${NAMESPACE}:9092"
CONSUMER_GROUPS=("nwdaf-clickhouse" "policysender")
TOPICS=("ipmdn-nwdaf-3g" "ipmdn-nwdaf-4g" "ipmdn-nwdaf-5g" "usercontrol")

# 사용법 출력
usage() {
    echo "사용법: $0 [포트번호]"
    echo "기본적으로 9094 포트를 확인하며, 다른 포트를 확인하려면 인자로 포트번호를 입력하세요."
    exit 1
}

# 스크립트 실행 시 -h 또는 --help 옵션이 입력되면 사용법 출력
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
fi

# 확인할 포트 설정 (기본값: 9094)
PORT=${1:-9094}

# 컨트롤러 및 브로커 파드 목록 가져오기
CONTROLLER_PODS=$(oc get pod -n $NAMESPACE -l strimzi.io/controller-role=true -o jsonpath='{.items[*].metadata.name}')
BROKER_PODS=($(oc get pod -n $NAMESPACE -l strimzi.io/broker-role=true -o jsonpath='{.items[*].metadata.name}'))
OTHER_PODS=("kafka-entity-operator" "kafka-kafka-exporter" "strimzi-cluster-operator")

echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo "===== Kafka 브로커 ${PORT} 포트 확인 ====="
if [ ${#BROKER_PODS[@]} -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - kafka 브로커 파드가 없습니다."
    exit 1
fi

# 각 파드에서 netstat 실행
for POD in "${BROKER_PODS[@]}"; do
    echo "Checking pod: $POD"
    oc exec -n $NAMESPACE "$POD" -- netstat -antp | grep $PORT || echo "$(date '+%Y-%m-%d %H:%M:%S') - 포트 $PORT가 LISTEN 상태가 아닙니다."
    echo "--------------------------------------------------"
done