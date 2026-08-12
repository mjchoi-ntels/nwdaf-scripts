#!/bin/bash
# filepath: d:\7. Personal\git\scripts\usercontrol-send.sh
# 성능 개선을 위해 모든 라인을 한 번에 처리하여 Kafka로 전송하는 방식으로 변경

while true; do
  # 현재 UTC 날짜/시간 변수에 저장
  CURRENT_DATETIME=$(TZ=UTC date +%Y-%m-%dT%H:%M)
  CURRENT_DATE=$(TZ=UTC date +%Y-%m-%d)
  
  # 현재 월의 첫째 날과 마지막 날 계산
  MONTH_START=$(TZ=UTC date +%Y-%m-01)
  MONTH_END=$(TZ=UTC date -d "$(TZ=UTC date +%Y-%m-01) +1 month -1 day" +%Y-%m-%d)
  
  # 전송 시작 시간 기록
  START_TIME=$(date +%s)
  
  # 임시 파일 생성
  TEMP_FILE="/tmp/kafka_messages_$$.txt"
  
  # 모든 라인의 날짜/시간을 치환한 후 임시 파일에 저장
  # 1. created_at과 window_end의 날짜/시간을 현재 시간으로 변경 (타임존 정보 포함 지원)
  # 2. cron 필드 내의 startdate와 enddate를 현재 월 기준으로 변경
  sed -E "s/\"(created_at|window_end)\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\+[0-9]{2}:[0-9]{2})?\"/\"\1\":\"${CURRENT_DATETIME}:00+00:00\"/g; s/\"startdate\":\"[0-9-]*\"/\"startdate\":\"${MONTH_START}\"/g; s/\"enddate\":\"[0-9-]*\"/\"enddate\":\"${MONTH_END}\"/g" usercontrol-sample.txt > "$TEMP_FILE"
  
  # 메시지 개수 계산
  MSG_COUNT=$(wc -l < "$TEMP_FILE")
  
  # 임시 파일에서 읽어 Kafka로 전송
  cat "$TEMP_FILE" | oc exec -i -n strimzi-kafka kafka-pool-nwdaf-wk01-3 -- bash -c \
    "/opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic usercontrol"
  
  # 임시 파일 삭제
  rm -f "$TEMP_FILE"
  
  # 전송 종료 시간 계산
  END_TIME=$(date +%s)
  ELAPSED=$((END_TIME - START_TIME))
  
  # 초당 전송 메시지 개수 출력
  if [ $ELAPSED -gt 0 ]; then
    MSG_PER_SEC=$((MSG_COUNT / ELAPSED))
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 전송 완료: ${MSG_COUNT}개 메시지, ${ELAPSED}초 소요, 초당 ${MSG_PER_SEC}개"
  else
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 전송 완료: ${MSG_COUNT}개 메시지"
  fi

  # 10초 대기
  sleep 10
done