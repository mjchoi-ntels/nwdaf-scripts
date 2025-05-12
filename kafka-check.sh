#!/bin/bash

NAMESPACE="strimzi-kafka"
BOOTSTRAP_SERVER="kafka-kafka-bootstrap.${NAMESPACE}:9092"
CONSUMER_GROUPS=("nwdaf-clickhouse" "policysender")
TOPICS=("ipmdn-nwdaf-3g" "ipmdn-nwdaf-4g" "ipmdn-nwdaf-5g" "usercontrol")

# 컨트롤러 및 브로커 파드 목록 가져오기
CONTROLLER_PODS=$(oc get pod -n $NAMESPACE -l strimzi.io/controller-role=true -o jsonpath='{.items[*].metadata.name}')
BROKER_PODS=($(oc get pod -n $NAMESPACE -l strimzi.io/broker-role=true -o jsonpath='{.items[*].metadata.name}'))
OTHER_PODS=("kafka-entity-operator" "kafka-kafka-exporter" "strimzi-cluster-operator")

echo "===== Kafka 컨트롤러 상태 확인 ====="
oc get pod -n $NAMESPACE -l strimzi.io/controller-role=true

echo ""
echo "===== Kafka 브로커 상태 확인 ====="
oc get pod -n $NAMESPACE -l strimzi.io/broker-role=true

echo ""
echo "===== Kafka 관련 기타 서비스 상태 확인 ====="
echo "NAME                                       READY   STATUS    RESTARTS   AGE"
oc get pod -n $NAMESPACE -l "app.kubernetes.io/name=entity-operator" --no-headers | awk '{printf "%-42s %-6s %-10s %-10s %-6s\n", $1, $2, $3, $4, $5}'
oc get pod -n $NAMESPACE -l "app.kubernetes.io/name=kafka-exporter" --no-headers | awk '{printf "%-42s %-6s %-10s %-10s %-6s\n", $1, $2, $3, $4, $5}'
oc get pod -n $NAMESPACE -l "name=strimzi-cluster-operator" --no-headers | awk '{printf "%-42s %-6s %-10s %-10s %-6s\n", $1, $2, $3, $4, $5}'

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

echo ""
echo "===== Consumer Group Lag 확인 (Topic별 출력) ====="
for group in "${CONSUMER_GROUPS[@]}"; do
    echo "Consumer Group: $group"
    prev_topic=""

    exec_on_working_broker "/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server $BOOTSTRAP_SERVER --group $group --describe 2>/dev/null | grep -Ev 'Defaulted container|^>> 시도 중' | awk '{
        consumer_id = length(\$7) > 30 ? substr(\$7, 1, 30) \"...\" : \$7;
        printf \"%-20s %-20s %-10s %-15s %-15s %-10s %-33s\n\", \$1, \$2, \$3, \$4, \$5, \$6, consumer_id
    }' | sort -k2,2 -k3,3n | awk '{
        if (\$2 != prev_topic) {
            if (prev_topic != \"\") print \"------------------\";
            prev_topic = \$2;
        }
        print;
    }'"

    echo ""
done


#echo "===== 토픽 상태 확인 ====="
#for topic in "${TOPICS[@]}"; do
#    echo "Topic: $topic"
#    exec_on_working_broker "/opt/kafka/bin/kafka-topics.sh --describe --topic $topic --bootstrap-server $BOOTSTRAP_SERVER"
#    echo ""
#done

#echo "===== Kafka Cluster Metadata 확인 ====="
#exec_on_working_broker "
#    SNAPSHOT_FILE=\$(ls -t /var/lib/kafka/data/meta.properties | head -n1)
#    if [[ -z \"\$SNAPSHOT_FILE\" ]]; then
#        echo '메타데이터 스냅샷 파일을 찾을 수 없음!'
#        exit 1
#    fi
#    /opt/kafka/bin/kafka-metadata-shell.sh --snapshot \$SNAPSHOT_FILE
#"

#echo "===== Kafka Controller 정보 확인 ====="
#for pod in $CONTROLLER_PODS; do
#    echo ">> Controller: $pod"
#    oc exec -n $NAMESPACE $pod -- /opt/kafka/bin/kafka-metadata-shell.sh list
#    echo ""
#done


echo ""
echo "===== Kafka Topic별 메시지 수 (logEndOffset) 집계 ====="

for topic in "${TOPICS[@]}"; do
    echo -n ">> $topic: "

    OFFSET_OUTPUT=$(exec_on_working_broker "/opt/kafka/bin/kafka-run-class.sh kafka.tools.GetOffsetShell --broker-list $BOOTSTRAP_SERVER --topic $topic --time -1 --offsets 1" 2>/dev/null)

    if [ -z "$OFFSET_OUTPUT" ]; then
        echo "정보 없음 (broker 모두 실패)"
    else
        echo "$OFFSET_OUTPUT" | awk -F ':' '{sum += $3} END {print sum}'
    fi
done

