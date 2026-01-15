#!/bin/bash

while true; do
  # 현재 UTC 시간(T%H:%M) 변수에 저장
  TIME=$(TZ=UTC date +T%H:%M)

  # usercontrol-sample.txt의 모든 줄에 대해 시간 치환 후 Kafka에 전송
  while IFS= read -r line; do
    DATA=$(echo "$line" | sed "s/T05:24/${TIME}/g")
    oc exec -n strimzi-kafka kafka-pool-nwdaf-wk01-3 -- bash -c \
      "echo '${DATA}' | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic usercontrol"
  done < usercontrol-sample.txt

  # 10초 대기
  sleep 10
done

-------

# #!/bin/bash

# while true; do
#   # 현재 UTC 시간(T%H:%M) 변수에 저장
#   TIME=$(TZ=UTC date +T%H:%M)

#   # usercontrol-sample.txt에서 첫 줄(LTE)과 마지막 줄(NR) 추출 후, 시간 치환
#   LTE=$(head -1 usercontrol-sample.txt | sed "s/T05:24/${TIME}/g")
#   NR=$(tail -1 usercontrol-sample.txt | sed "s/T05:24/${TIME}/g")

#   # LTE 데이터 Kafka에 전송
#   oc exec -n strimzi-kafka kafka-pool-nwdaf-wk01-3 -- bash -c \
#     "echo '${LTE}' | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic usercontrol"

#   # NR 데이터 Kafka에 전송
#   oc exec -n strimzi-kafka kafka-pool-nwdaf-wk01-3 -c kafka -- bash -c \
#     "echo '${NR}' | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic usercontrol"

#   # 10초 대기
#   sleep 10
# done

--------

#!/bin/bash
# filepath: d:\7. Personal\git\scripts\usercontrol-send.sh

while true; do
  # 현재 UTC 시간(T%H:%M) 변수에 저장
  TIME=$(TZ=UTC date +T%H:%M)

  # 모든 라인의 시간을 치환한 후 한 번에 Kafka로 전송
  sed "s/T05:24/${TIME}/g" usercontrol-sample.txt | \
  oc exec -i -n strimzi-kafka kafka-pool-nwdaf-wk01-3 -- bash -c \
    "/opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic usercontrol"

  # 10초 대기
  sleep 10
done