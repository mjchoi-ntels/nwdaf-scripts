#!/bin/bash

show_help() {
    echo "사용법: $0 [INTERVAL] [COUNT]"
    echo "  INTERVAL: 메시지 송신 간격(초), 기본값 0"
    echo "  COUNT   : 메시지 송신 횟수, 기본값 1"
    echo "  -h, --help: 도움말 출력"
}

# 도움말 옵션 처리
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

# 인자: 송신간격(초), 송신횟수(회)
INTERVAL=${1:-0}
COUNT=${2:-1}

# Kafka 네임스페이스
KAFKA_NS="strimzi-kafka"

# 우선 순위 순으로 Kafka 파드 리스트
KAFKA_PODS=("kafka-pool-nwdaf-wk01-3" "kafka-pool-nwdaf-wk02-4" "kafka-pool-nwdaf-wk03-5")

# 사용 가능한 Kafka 파드 선택 (Running 상태 & Ready 컨테이너 확인 포함)
for POD in "${KAFKA_PODS[@]}"; do
  STATUS=$(oc get pod "$POD" -n "$KAFKA_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  READY=$(oc get pod "$POD" -n "$KAFKA_NS" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
  
  if [[ "$STATUS" == "Running" && "$READY" == "true" ]]; then
    KAFKA_POD="$POD"
    break
  fi
done

# 사용 가능한 파드가 없을 경우 종료
if [[ -z "$KAFKA_POD" ]]; then
  echo "사용 가능한 Kafka 파드를 찾을 수 없습니다."
  exit 1
fi

echo "Kafka Pod 선택됨: $KAFKA_POD"
echo "송신 간격: $INTERVAL 초, 송신 횟수: $COUNT 회"

for ((i=1; i<=COUNT; i++)); do
  CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
  WINDOW_END=$(date -u +"%Y-%m-%dT%H:%M:00+00:00")

  # 필드 정의
  MDN="01092105121"
  MIN="${MDN:1}"
  CELL_ID="1186831:0"
  CELL_TYPE="5g"
  CELL_GROUP_ID="testGroup"
  USER_SPEED_THRESHOLD=0
  USER_CONTROL_SPEED=7000000
  USER_CONTROL_QOS="QoS7M_NoGBR"
  PRB_USAGE_THRESHOLD=0
  PRB_USAGE_PREDICTED=80
  TIMER=60
  CRON_JSON='{\"cron\":\"* 2-31 4-5 * 2025\",\"startdate\":\"2025-04-02\",\"enddate\":\"2025-05-31\"}'
  DL_USAGE=1766806977
  UL_USAGE=124971
  DURATION=17
  DL_BPS=2852599657
  UL_BPS=58809
  USER_GRADE="heavy"
  PGW_IP="10.20.30.40"
  PGW_REGION_CODE=0

  MESSAGE=$(cat <<EOF
{"created_at":"$CREATED_AT","window_end":"$WINDOW_END","min":"$MIN","mdn":"$MDN","cell_id":"$CELL_ID","cell_type":"$CELL_TYPE","cell_group_id":"$CELL_GROUP_ID","user_speed_threshold":$USER_SPEED_THRESHOLD,"user_control_speed":$USER_CONTROL_SPEED,"user_control_qos":"$USER_CONTROL_QOS","prb_usage_threshold":$PRB_USAGE_THRESHOLD,"prb_usage_predicted":$PRB_USAGE_PREDICTED,"timer":$TIMER,"cron":"$CRON_JSON","dl_usage":$DL_USAGE,"ul_usage":$UL_USAGE,"duration":$DURATION,"dl_bps":$DL_BPS,"ul_bps":$UL_BPS,"user_grade":"$USER_GRADE","pgw_ip":"$PGW_IP","pgw_region_code":$PGW_REGION_CODE}
EOF
)

  # Kafka 메시지 전송
  echo "$MESSAGE" | oc exec -n "$KAFKA_NS" "$KAFKA_POD" -- \
    /opt/kafka/bin/kafka-console-producer.sh \
    --broker-list kafka-kafka-bootstrap:9092 \
    --topic usercontrol

  echo "[$i/$COUNT] 메시지 전송 완료"

  # 마지막이 아닐 경우 간격 대기
  if [[ $i -lt $COUNT ]]; then
    sleep "$INTERVAL"
  fi
done