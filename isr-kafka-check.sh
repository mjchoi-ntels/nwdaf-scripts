#!/bin/bash

NAMESPACE="strimzi-kafka"
BOOTSTRAP_SERVER="kafka-kafka-bootstrap.${NAMESPACE}:9092"
CONSUMER_GROUPS=("nwdaf-clickhouse" "policysender")
TOPICS=("ipmdn-nwdaf-3g" "ipmdn-nwdaf-4g" "ipmdn-nwdaf-5g" "usercontrol")

# 확인할 포트 설정 (기본값: 9094)
PORT=${1:-9094}

# 컨트롤러 및 브로커 파드 목록 가져오기
CONTROLLER_PODS=$(oc get pod -n $NAMESPACE -l strimzi.io/controller-role=true -o jsonpath='{.items[*].metadata.name}')
BROKER_PODS=($(oc get pod -n $NAMESPACE -l strimzi.io/broker-role=true -o jsonpath='{.items[*].metadata.name}'))
OTHER_PODS=("kafka-entity-operator" "kafka-kafka-exporter" "strimzi-cluster-operator")

# 정상 동작하는 브로커 찾기
function exec_on_working_broker() {
    local CMD=$1
    for BROKER in "${BROKER_PODS[@]}"; do
        echo ">> 시도 중: $BROKER"
        if oc exec -n $NAMESPACE $BROKER -- bash -c "$CMD" 2>&1 | awk '!/Defaulted container/ {print}'; then
            return 0
        else
            echo "$BROKER 실행 실패, 다음 브로커 시도..."
        fi
    done
    echo "모든 브로커에서 명령 실행 실패!"
    return 1
}

echo "===== 토픽 상태 확인 ====="
for topic in "${TOPICS[@]}"; do
   echo "Topic: $topic"
   exec_on_working_broker "/opt/kafka/bin/kafka-topics.sh --describe --topic $topic --bootstrap-server $BOOTSTRAP_SERVER"
   echo ""
done

# echo "===== Kafka Cluster Metadata 확인 ====="
# exec_on_working_broker "
#    SNAPSHOT_FILE=\$(ls -t /var/lib/kafka/data/meta.properties | head -n1)
#    if [[ -z \"\$SNAPSHOT_FILE\" ]]; then
#        echo '메타데이터 스냅샷 파일을 찾을 수 없음!'
#        exit 1
#    fi
#    /opt/kafka/bin/kafka-metadata-shell.sh --snapshot \$SNAPSHOT_FILE
# "

# echo "===== Kafka Controller 정보 확인 ====="
# for pod in $CONTROLLER_PODS; do
#    echo ">> Controller: $pod"
#    oc exec -n $NAMESPACE $pod -- /opt/kafka/bin/kafka-metadata-shell.sh list
#    echo ""
# done