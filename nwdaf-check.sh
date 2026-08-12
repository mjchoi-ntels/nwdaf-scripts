#!/bin/bash

# Verify oc login user is nwdaf-admin
current_user=$(oc whoami 2>/dev/null || echo "")
if [ "$current_user" != "nwdaf-admin" ]; then
    echo "현재 로그인된 계정은 '$current_user' — 권한이 있는 계정으로 로그인해주세요. 종료합니다." >&2
    exit 1
fi

# Kubernetes 클러스터 점검 스크립트
echo ""
echo "======================================"
echo " K8s 클러스터 점검 체크리스트"
echo "======================================"

# 실행일시 출력 (KST)
EXEC_TIME_KST=$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S %Z')
echo "실행일시 (KST): $EXEC_TIME_KST"

# 1. K8S 노드 연결 상태
echo ""
echo "[1] K8S 노드 연결 상태"
node_status=$(oc get nodes --no-headers | awk '{print $2}' | sort | uniq)
not_ready_nodes=$(oc get nodes --no-headers | awk '$2 != "Ready" {print $1}')
if [[ "$node_status" == "Ready" ]] && [[ -z "$not_ready_nodes" ]]; then
    echo "=> 모든 NWDAF 노드의 STATUS가 READY입니다. [OK]"
else
    if [[ -z "$not_ready_nodes" ]]; then
        echo "=> 일부 노드의 상태가 정상적으로 표시되지 않습니다. [INFO]"
    else
        echo "=> READY가 아닌 노드가 존재합니다: $not_ready_nodes [CRITICAL]"
    fi
fi

# 노드 목록 출력: 패턴에 맞는 노드만 표시
echo ""
filtered_nodes=$(oc get nodes 2>/dev/null | grep -E 'ma[1-3]\.ocp|nwdaf-wk0[1-3]' || true)
if [[ -z "$filtered_nodes" ]]; then
    echo "  해당 패턴의 노드 없음"
else
    echo "$filtered_nodes"
fi

# 2. K8S 노드별 시스템 부하 상태 (필터된 노드만 점검)
echo ""
echo "[2] K8S 노드별 시스템 부하 상태"

# 전체 노드 대신 필터로 선택된 노드만 사용
# oc adm top nodes 출력에서 필터 패턴에 맞는 노드만 골라서 판정
top_all=$(oc adm top nodes --no-headers 2>/dev/null || true)
top_filtered=$(echo "$top_all" | grep -E 'ma[1-3]\.ocp|nwdaf-wk0[1-3]' || true)

if [[ -z "$(echo "$top_filtered" | tr -d '[:space:]')" ]]; then
    echo "=> 필터에 해당하는 노드의 리소스 사용량을 가져오지 못했습니다 또는 해당 노드 없음"
    cpu_over=""
    mem_over=""
    cpu_warn=""
    mem_warn=""
else
    # 로그는 나중에 보여주고, 먼저 판별용 변수들을 계산해 둠
    cpu_over=$(echo "$top_filtered" | awk '$3+0 > 90 {print $1":"$3}')
    mem_over=$(echo "$top_filtered" | awk '$5+0 > 90 {print $1":"$5}')
    cpu_warn=$(echo "$top_filtered" | awk '$3+0 > 70 && $3+0 <= 90 {print $1":"$3}')
    mem_warn=$(echo "$top_filtered" | awk '$5+0 > 70 && $5+0 <= 90 {print $1":"$5}')
fi

## 판별 코멘트를 먼저 출력 (요약 한 줄로 표시)
if [[ -z "$cpu_over" && -z "$mem_over" && -z "$cpu_warn" && -z "$mem_warn" ]]; then
    echo "=> 모든 노드의 CPU/Memory 부하가 70% 이하입니다. [OK]"
else
    # 우선 중요도 순으로 한 줄 요약만 출력 (세부 정보는 아래의 원본 로그에서 확인 가능)
    if [[ -n "$cpu_over" || -n "$mem_over" ]]; then
        echo "=> CPU/Memory 부하가 90%를 초과한 노드가 있습니다. [CRITICAL]"
    elif [[ -n "$cpu_warn" || -n "$mem_warn" ]]; then
        echo "=> CPU/Memory 부하가 70% 초과~90% 이하인 노드가 있습니다. [WARNING]"
    else
        echo "=> CPU/Memory 부하 이상 감지됨. [WARNING]"
    fi
fi

# 판별 후에 원본 로그(필터된 `oc adm top nodes`)를 출력
if [[ -n "$(echo "$top_filtered" | tr -d '[:space:]')" ]]; then
    echo ""
    echo "$top_filtered"
fi

# 3. 네임스페이스별 K8S 이벤트 확인 (가독성 향상)
echo ""
echo "[3] 네임스페이스별 K8S 이벤트 확인"
# 전역 요약 플래그: 모든 네임스페이스에서 Warning이 없으면 0, 하나라도 있으면 1
overall_warnings_found=0
TMP_REPORT=$(mktemp)
for ns in nwdaf kubeflow istio-system strimzi-kafka infra-datastore cert-manager auth infra-monitor metallb-system gpu-operator; do
    # collect one-line summary per namespace into TMP_REPORT

    # 간단 모드: Normal과 transient 이벤트는 무시하고, 나머지가 있으면 Warning으로 판단
    events_filtered=$(oc get event -n "$ns" --no-headers 2>&1 | grep -v -E '^$' | grep -v -E '\bNormal\b' | grep -v -E '\btransient\b' || true)

    if echo "$events_filtered" | grep -q "No resources found" || [[ -z "$(echo "$events_filtered" | tr -d '[:space:]')" ]]; then
        printf "%-15s %-10s %s\n" "$ns" "[OK]" "이벤트 없음" >> "$TMP_REPORT"
        : > /tmp/event_${ns}_last24h.txt
        continue
    fi

    # 경고성 이벤트가 존재하면 임시 파일에 저장하고 플래그 설정
    echo "$events_filtered" > /tmp/event_${ns}_last24h.txt
    warnings_found=1
    overall_warnings_found=1

    # 로그 전체 출력 대신 건수만 출력
    warn_count=$(echo "$events_filtered" | sed '/^\s*$/d' | wc -l | tr -d ' ')
    if [[ $warn_count -gt 0 ]]; then
        printf "%-15s %-10s %s\n" "$ns" "[WARNING]" "${warn_count}건" >> "$TMP_REPORT"
    else
        printf "%-15s %-10s %s\n" "$ns" "[OK]" "이벤트 없음" >> "$TMP_REPORT"
    fi
done

# 전체 네임스페이스 요약 출력 (먼저)
if [[ $overall_warnings_found -eq 0 ]]; then
    echo "=> 전체 네임스페이스에서 K8S 이벤트 특이사항이 없습니다. [OK]"
else
    echo "=> 일부 네임스페이스에서 Warning 이벤트가 존재합니다. [WARNING]"
fi

# 그 다음에 네임스페이스별 상세 출력 (깔끔한 표 형식)
printf "\n"
printf "%-15s %-10s %s\n" "NAMESPACE" "STATUS" "DETAILS"
printf "%s\n" "---------------------------------------------------------"
cat "$TMP_REPORT"
rm -f "$TMP_REPORT"

# 4. 네임스페이스별 파드 상태
echo ""
echo "[4] 네임스페이스별 파드 상태"

# 요약 보고용 임시 파일
TMP_POD_REPORT=$(mktemp)
overall_pod_issues=0

namespaces=(nwdaf kubeflow istio-system strimzi-kafka infra-datastore cert-manager auth infra-monitor metallb-system gpu-operator)

# 1) 각 네임스페이스를 순회하면서 한줄 요약을 TMP_POD_REPORT에 기록하고 상세 출력용 파일도 생성
for ns in "${namespaces[@]}"; do
    # 전체 파드(wide)에서 노드명이 'nwdaf'인 파드만 골라 정렬된 컬럼으로 출력
    pods_wide_all=$(oc get pod -n "$ns" -o wide --no-headers 2>/dev/null || true)

    # pods_formatted: NAME READY STATUS RESTARTS AGE 형식으로 고정 폭으로 포맷
    pods_formatted=$(echo "$pods_wide_all" | awk 'NF>=7 && $7 ~ /nwdaf/ {printf "%-36s %-6s %-10s %-8s %-4s\n", $1, $2, $3, $4, $5}')

    # 상세 출력용 파일 저장: 데이터가 있으면 헤더 포함, 없으면 빈 파일
    if [[ -z "$(echo "$pods_formatted" | tr -d '[:space:]')" ]]; then
        : > /tmp/pods_${ns}.txt
    else
        printf "%-36s %-6s %-10s %-8s %-4s\n" "NAME" "READY" "STATUS" "RESTARTS" "AGE" > /tmp/pods_${ns}.txt
        echo "$pods_formatted" >> /tmp/pods_${ns}.txt
    fi

    # 이슈 판별: 원본 wide 출력(필터된 행)에서 상태 키워드 검사
    pods_output_raw=$(echo "$pods_wide_all" | awk 'NF>=7 && $7 ~ /nwdaf/ {print}')
    issues=$(echo "$pods_output_raw" | grep -E 'Error|Failed|Unknown|Pending|CrashLoopBackOff' || true)

    if [[ -n "$issues" ]]; then
        issue_count=$(echo "$issues" | sed '/^\s*$/d' | wc -l | tr -d ' ')
        printf "%-15s %-10s %s\n" "$ns" "[CRITICAL]" "${issue_count}건 이상 상태" >> "$TMP_POD_REPORT"
        overall_pod_issues=1
    else
        # 빈 또는 정보 없음 케이스 구분 (필터된 결과 기준)
        if [[ -z "$(echo "$pods_output" | tr -d '[:space:]')" ]]; then
            printf "%-15s %-10s %s\n" "$ns" "[OK]" "이상 상태 없음" >> "$TMP_POD_REPORT"
        else
            printf "%-15s %-10s %s\n" "$ns" "[WARN]" "오류 발생" >> "$TMP_POD_REPORT"
        fi
    fi
done

# 2) 전체 네임스페이스 요약을 먼저 출력
if [[ $overall_pod_issues -eq 0 ]]; then
    echo "=> 전체 네임스페이스에서 이상 상태의 파드가 없습니다. [OK]"
else
    echo "=> 일부 네임스페이스에서 이상 상태의 파드가 있습니다. [CRITICAL]"
fi

# 3) 네임스페이스별 한줄 요약 표 출력
printf "\n"
printf "%-15s %-10s %s\n" "NAMESPACE" "STATUS" "DETAILS"
printf "%s\n" "---------------------------------------------------------"
cat "$TMP_POD_REPORT"
echo ""

# 4) 그 다음에 네임스페이스별 상세 출력(기존 출력 형식 유지)
for ns in "${namespaces[@]}"; do
    pods_slim=$(cat /tmp/pods_${ns}.txt 2>/dev/null || true)

    # 상세 출력: 네임스페이스 식별 코멘트를 추가한 뒤 간소화된 표만 출력 (들여쓰기 없음)
    if [[ -z "$(echo "$pods_slim" | tr -d '[:space:]')" ]]; then
        echo "## $ns: (파드 정보 없음)"
    else
        echo "## $ns 네임스페이스 파드 목록"
        echo "$pods_slim"
        echo ""
    fi
done

# 정리: 임시 파일 제거
rm -f "$TMP_POD_REPORT"
for ns in "${namespaces[@]}"; do
    rm -f /tmp/pods_${ns}.txt
done

echo "======================================"
echo " IPMDN 연동 (CDR 데이터) 점검"
echo "======================================"

NAMESPACE="strimzi-kafka"
BOOTSTRAP_SERVER="kafka-kafka-bootstrap.${NAMESPACE}:9092"
CONSUMER_GROUPS=("nwdaf-clickhouse" "policysender")
TOPICS=("ipmdn-nwdaf-3g" "ipmdn-nwdaf-4g" "ipmdn-nwdaf-5g" "usercontrol")
INTERVAL=3

# 컨트롤러 및 브로커 파드 목록 가져오기
CONTROLLER_PODS=$(oc get pod -n $NAMESPACE -l strimzi.io/controller-role=true -o jsonpath='{.items[*].metadata.name}')
BROKER_PODS=($(oc get pod -n $NAMESPACE -l strimzi.io/broker-role=true -o jsonpath='{.items[*].metadata.name}'))
OTHER_PODS=("kafka-entity-operator" "kafka-kafka-exporter" "strimzi-cluster-operator")

echo "[1] Kafka 컨트롤러 상태 확인"

# 판별용 먼저 실행: 컨트롤러 파드가 존재하고 모두 Running인지 검사
controller_pods=$(oc get pod -n $NAMESPACE -l strimzi.io/controller-role=true --no-headers 2>/dev/null || true)
if [[ -z "$(echo "$controller_pods" | tr -d '[:space:]')" ]]; then
    echo "=> Kafka controller 파드를 찾을 수 없습니다. [CRITICAL]"
else
    nonrunning=$(echo "$controller_pods" | awk '$3 != "Running" {print $1}' || true)
    if [[ -z "$(echo "$nonrunning" | tr -d '[:space:]')" ]]; then
        echo "=> Kafka 컨트롤러 파드가 모두 Running 상태입니다. [OK]"
    else
        echo "=> Running이 아닌 컨트롤러 파드: $nonrunning [CRITICAL]"
    fi
fi

# 로그(원본 출력)는 판별 코멘트 다음에 출력
oc get pod -n $NAMESPACE -l strimzi.io/controller-role=true

echo ""
echo "[2] Kafka 브로커 상태 확인"

# 판별용 먼저 실행: 브로커 파드가 존재하고 모두 Running인지 검사
broker_pods=$(oc get pod -n $NAMESPACE -l strimzi.io/broker-role=true --no-headers 2>/dev/null || true)
if [[ -z "$(echo "$broker_pods" | tr -d '[:space:]')" ]]; then
    echo "=> Kafka broker 파드를 찾을 수 없습니다. [CRITICAL]"
else
    nonrunning_brokers=$(echo "$broker_pods" | awk '$3 != "Running" {print $1}' || true)
    if [[ -z "$(echo "$nonrunning_brokers" | tr -d '[:space:]')" ]]; then
        echo "=> Kafka 브로커 파드가 모두 Running 상태입니다. [OK]"
    else
        echo "=> Running이 아닌 브로커 파드: $nonrunning_brokers [CRITICAL]"
    fi
fi

# 로그(원본 출력)는 판별 코멘트 다음에 출력
oc get pod -n $NAMESPACE -l strimzi.io/broker-role=true

echo ""
echo "[3] Kafka 관련 기타 서비스 상태 확인"

# 서비스별 판별 코멘트 먼저 출력 -> 로그(원본)는 그 다음 출력
# entity-operator
eo_pods=$(oc get pod -n $NAMESPACE -l "app.kubernetes.io/name=entity-operator" --no-headers 2>/dev/null || true)
if [[ -z "$(echo "$eo_pods" | tr -d '[:space:]')" ]]; then
    echo "=> entity-operator 파드를 찾을 수 없습니다. [CRITICAL]"
else
    eo_nonrun=$(echo "$eo_pods" | awk '$3 != "Running" {print $1}' || true)
    if [[ -z "$(echo "$eo_nonrun" | tr -d '[:space:]')" ]]; then
        echo "=> entity-operator 파드가 모두 Running 상태입니다. [OK]"
    else
        echo "=> Running이 아닌 entity-operator 파드: $eo_nonrun [CRITICAL]"
    fi
fi

# kafka-exporter
ke_pods=$(oc get pod -n $NAMESPACE -l "app.kubernetes.io/name=kafka-exporter" --no-headers 2>/dev/null || true)
if [[ -z "$(echo "$ke_pods" | tr -d '[:space:]')" ]]; then
    echo "=> kafka-exporter 파드를 찾을 수 없습니다. [CRITICAL]"
else
    ke_nonrun=$(echo "$ke_pods" | awk '$3 != "Running" {print $1}' || true)
    if [[ -z "$(echo "$ke_nonrun" | tr -d '[:space:]')" ]]; then
        echo "=> kafka-exporter 파드가 모두 Running 상태입니다. [OK]"
    else
        echo "=> Running이 아닌 kafka-exporter 파드: $ke_nonrun [CRITICAL]"
    fi
fi

# strimzi-cluster-operator
sco_pods=$(oc get pod -n $NAMESPACE -l "name=strimzi-cluster-operator" --no-headers 2>/dev/null || true)
if [[ -z "$(echo "$sco_pods" | tr -d '[:space:]')" ]]; then
    echo "=> strimzi-cluster-operator 파드를 찾을 수 없습니다. [CRITICAL]"
else
    sco_nonrun=$(echo "$sco_pods" | awk '$3 != "Running" {print $1}' || true)
    if [[ -z "$(echo "$sco_nonrun" | tr -d '[:space:]')" ]]; then
        echo "=> strimzi-cluster-operator 파드가 모두 Running 상태입니다. [OK]"
    else
        echo "=> Running이 아닌 strimzi-cluster-operator 파드: $sco_nonrun [CRITICAL]"
    fi
fi

echo ""
echo "NAME                                       READY   STATUS    RESTARTS   AGE"
oc get pod -n $NAMESPACE -l "app.kubernetes.io/name=entity-operator" --no-headers | awk '{printf "%-42s %-6s %-10s %-10s %-6s\n", $1, $2, $3, $4, $5}'
oc get pod -n $NAMESPACE -l "app.kubernetes.io/name=kafka-exporter" --no-headers | awk '{printf "%-42s %-6s %-10s %-10s %-6s\n", $1, $2, $3, $4, $5}'
oc get pod -n $NAMESPACE -l "name=strimzi-cluster-operator" --no-headers | awk '{printf "%-42s %-6s %-10s %-10s %-6s\n", $1, $2, $3, $4, $5}'


# echo "[LAG 점검]"
# NAMESPACE="strimzi-kafka"
# POD="kafka-pool-nwdaf-wk01-3"
# GROUP="nwdaf-clickhouse"
# KAFKA_CMD="/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --group $GROUP --describe"
# TOPICS=("ipmdn-nwdaf-4g" "ipmdn-nwdaf-5g" "ipmdn-nwdaf-3g" "usercontrol")
# LOG_FILE="kafka_lag_history.log"

# # 변화폭 임계값(정수, 100분율) - bc가 없으므로 정수로 계산 (10=10%, 30=30%)
# THRESHOLD_WARNING=10   # 10% 이상 변화시 WARNING
# THRESHOLD_CRITICAL=30  # 30% 이상 변화시 CRITICAL

# ITERATIONS=5
# INTERVAL=3   # 반복 간격(초)

# declare -A LAG_HISTORY

# get_lag() {
#   local topic=$1
#   local result
#   result=$(oc exec -n $NAMESPACE $POD -- $KAFKA_CMD 2>/dev/null | grep "$topic" | awk '{print $3, $6}')
#   echo "$result"
# }

# echo "======================================"
# echo " Kafka Topic Lag 변화폭 체크 (5회 반복)"
# echo "======================================"

# for ((i=1; i<=ITERATIONS; i++)); do
#   for topic in "${TOPICS[@]}"; do
#     lag_sum=0
#     lag_count=0
#     while read -r partition lag; do
#       if [[ "$lag" =~ ^[0-9]+$ ]]; then
#         lag_sum=$((lag_sum + lag))
#         lag_count=$((lag_count + 1))
#       fi
#     done < <(get_lag $topic)

#     if [ $lag_count -gt 0 ]; then
#       avg_lag=$((lag_sum / lag_count))
#     else
#       avg_lag=0
#     fi

#     # 히스토리에 기록 (콤마로 연결)
#     if [ -z "${LAG_HISTORY[$topic]}" ]; then
#       LAG_HISTORY[$topic]="$avg_lag"
#     else
#       LAG_HISTORY[$topic]+=",$avg_lag"
#     fi

#     echo "$(date '+%Y-%m-%d %H:%M:%S') [ITER $i] $topic 평균 Lag: $avg_lag" | tee -a $LOG_FILE
#   done

#   if [ $i -lt $ITERATIONS ]; then
#     sleep $INTERVAL
#   fi
# done

# echo ""
# echo "----- Kafka Lag 변화폭 분석 결과 -----" | tee -a $LOG_FILE
# for topic in "${TOPICS[@]}"; do
#   IFS=',' read -ra lag_values <<< "${LAG_HISTORY[$topic]}"
#   min="${lag_values[0]}"
#   max="${lag_values[0]}"
#   first="${lag_values[0]}"
#   last="${lag_values[-1]}"
#   for v in "${lag_values[@]}"; do
#     (( v < min )) && min=$v
#     (( v > max )) && max=$v
#   done

#   # 변화율 계산 (정수 연산, 100 곱해서 100분율로)
#   if [ "$first" -gt 0 ]; then
#     diff=$((last - first))
#     abs_diff=$diff
#     [ $diff -lt 0 ] && abs_diff=$(( -diff ))
#     pct=$(( abs_diff * 100 / first ))  # 정수(%)로 계산

#     if [ $pct -ge $THRESHOLD_CRITICAL ]; then
#       status="CRITICAL"
#       message="Lag 변화폭 CRITICAL: 시작=$first, 종료=$last (Δ=$diff, 변화율=${pct}%)"
#     elif [ $pct -ge $THRESHOLD_WARNING ]; then
#       status="WARNING"
#       message="Lag 변화폭 WARNING: 시작=$first, 종료=$last (Δ=$diff, 변화율=${pct}%)"
#     else
#       status="OK"
#       message="Lag 변화 정상: 시작=$first, 종료=$last (Δ=$diff, 변화율=${pct}%)"
#     fi
#     echo "[${status}] $topic $message | Max: $max, Min: $min, 측정값: ${LAG_HISTORY[$topic]}" | tee -a $LOG_FILE
#   else
#     echo "[INIT] $topic: Lag 측정값: ${LAG_HISTORY[$topic]} (변화폭 판단 불가: 시작값 미정)" | tee -a $LOG_FILE
#   fi
# done

# mjchoi 추가 2026-02
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
echo "[4] Consumer Group Lag 확인 (Topic별 출력 - 3회 반복 측정)"
for group in "${CONSUMER_GROUPS[@]}"; do
    echo "Consumer Group: $group"
    
    # 3회 LAG 수집을 위한 임시 파일
    TMP_LAG1=$(mktemp)
    TMP_LAG2=$(mktemp)
    TMP_LAG3=$(mktemp)
    
    # 첫 번째 측정 (TOPIC, PARTITION, LAG, CONSUMER-ID)
    exec_on_working_broker "/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server $BOOTSTRAP_SERVER --group $group --describe 2>/dev/null" | \
        grep -Ev 'Defaulted container|^>> 시도 중|^GROUP|^Consumer group' | \
        awk 'NF>=6 {
            cid=$7;
            n=split(cid, arr, /[-_.]/);
            newcid=""; prev="";
            for(i=1;i<=n;i++){
                tok=arr[i]; l=tolower(tok);
                if(l!=prev){ if(newcid=="") newcid=tok; else newcid=newcid"-"tok; prev=l }
            }
            if(newcid=="") newcid=cid;
            if(length(newcid)>30) newcid=substr(newcid,1,30)"...";
            print $2"\t"$3"\t"$6"\t"newcid
        }' | sort > $TMP_LAG1
    
    sleep $INTERVAL
    
    # 두 번째 측정 (TOPIC, PARTITION, LAG, CONSUMER-ID)
    exec_on_working_broker "/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server $BOOTSTRAP_SERVER --group $group --describe 2>/dev/null" | \
        grep -Ev 'Defaulted container|^>> 시도 중|^GROUP|^Consumer group' | \
        awk 'NF>=6 {
            cid=$7;
            n=split(cid, arr, /[-_.]/);
            newcid=""; prev="";
            for(i=1;i<=n;i++){
                tok=arr[i]; l=tolower(tok);
                if(l!=prev){ if(newcid=="") newcid=tok; else newcid=newcid"-"tok; prev=l }
            }
            if(newcid=="") newcid=cid;
            if(length(newcid)>30) newcid=substr(newcid,1,30)"...";
            print $2"\t"$3"\t"$6"\t"newcid
        }' | sort > $TMP_LAG2
    
    sleep $INTERVAL
    
    # 세 번째 측정 (TOPIC, PARTITION, LAG, CONSUMER-ID)
    exec_on_working_broker "/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server $BOOTSTRAP_SERVER --group $group --describe 2>/dev/null" | \
        grep -Ev 'Defaulted container|^>> 시도 중|^GROUP|^Consumer group' | \
        awk 'NF>=6 {
            cid=$7;
            n=split(cid, arr, /[-_.]/);
            newcid=""; prev="";
            for(i=1;i<=n;i++){
                tok=arr[i]; l=tolower(tok);
                if(l!=prev){ if(newcid=="") newcid=tok; else newcid=newcid"-"tok; prev=l }
            }
            if(newcid=="") newcid=cid;
            if(length(newcid)>30) newcid=substr(newcid,1,30)"...";
            print $2"\t"$3"\t"$6"\t"newcid
        }' | sort > $TMP_LAG3
    
    # 결과 출력 (헤더)
    printf "%-20s %-20s %-10s %-12s %-12s %-12s %-33s\n" "GROUP" "TOPIC" "PARTITION" "LAG-1" "LAG-2" "LAG-3" "CONSUMER-ID"
    
    # 3개 파일 병합 및 출력
    prev_topic=""
    paste $TMP_LAG1 $TMP_LAG2 $TMP_LAG3 | awk -F'\t' -v grp="$group" '{
        topic1=$1; partition1=$2; lag1=$3; cid1=$4;
        topic2=$5; partition2=$6; lag2=$7; cid2=$8;
        topic3=$9; partition3=$10; lag3=$11; cid3=$12;

        if (topic1 == topic2 && topic2 == topic3 && partition1 == partition2 && partition2 == partition3) {
            topic = topic1;
            partition = partition1;

            if (topic != prev_topic && prev_topic != "") {
                print "------------------";
            }
            prev_topic = topic;

            cid = (cid1 != "" ? cid1 : (cid2 != "" ? cid2 : cid3));
            printf "%-20s %-20s %-10s %-12s %-12s %-12s %-33s\n", grp, topic, partition, lag1, lag2, lag3, cid;
        }
    }'
    
    # 임시 파일 삭제
    rm -f $TMP_LAG1 $TMP_LAG2 $TMP_LAG3
    
    echo ""
done

echo "[4] CDR 데이터 DB 적재 상태 체크"
CDR_DB=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c "clickhouse-client --password=\$CLICKHOUSE_ADMIN_PASSWORD -d nwdaf -q \"SELECT event_time, count(*) FROM stat_ipmdn_recv WHERE event_time > now() - toIntervalSecond(20) GROUP BY event_time ORDER BY event_time DESC LIMIT 5\"" 2>/dev/null || true)

# CDR presence check: rows -> OK, no rows -> CRITICAL
CDR_ROWS=$(echo "$CDR_DB" | sed '/^\s*$/d' | wc -l | tr -d ' ')
if [[ -n "$(echo "$CDR_DB" | tr -d '[:space:]')" && "$CDR_ROWS" -ge 1 ]]; then
    echo "=> CDR 데이터가 정상적으로 적재되고 있습니다. [OK]"
    # show rows indented
    echo "$CDR_DB" | sed 's/^/  /'
else
    echo "=> CDR 데이터가 정상적으로 적재되지 않고 있습니다. [CRITICAL]"
    echo "  (rows: ${CDR_ROWS:-0})"
fi

echo ""
echo "======================================"
echo " IDCUBE Datagw 연동 (PRB 데이터) 점검"
echo "======================================"
echo "[1] datagw cronjob 상태 체크"
datagw_jobs=$(oc get pod -n nwdaf | grep datagw | grep -E 'Error')
if [[ -z "$datagw_jobs" ]]; then
    echo "=> 상태값이 Error로 종료된 job이 없습니다. [OK]"
else
    echo "=> Error로 종료된 job: $datagw_jobs [CRITICAL]"
fi

# 추가 출력: datagw 관련 파드 전체 목록 출력
echo "" 
datagw_pods_full=$(oc get pod -n nwdaf | grep datagw 2>&1 || true)
if [[ -z "$(echo \"$datagw_pods_full\" | tr -d '[:space:]')" ]]; then
    echo "    (datagw 파드 정보 없음)"
else
    echo "$datagw_pods_full" | sed 's/^/  /'
fi

echo ""
echo "[2] PRB 데이터 DB 적재 상태 체크"
# Check PRB counts within the last 1 hour
# Fetch raw rows (event_date count) up to 5 per table
PRB_4G_RAW=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c "clickhouse-client --password=\$CLICKHOUSE_ADMIN_PASSWORD -d nwdaf -q \"SELECT event_date, count() FROM t_4g_cell_prb_5m WHERE event_date >= now() - INTERVAL 1 hour GROUP BY event_date ORDER BY event_date LIMIT 5\"" 2>/dev/null || true)
PRB_5G_RAW=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c "clickhouse-client --password=\$CLICKHOUSE_ADMIN_PASSWORD -d nwdaf -q \"SELECT event_date, count() FROM t_5g_cell_prb_15m WHERE event_date >= now() - INTERVAL 1 hour GROUP BY event_date ORDER BY event_date LIMIT 5\"" 2>/dev/null || true)

# Normalize and compute row counts and summed counts
PRB_4G_ROWS=$(echo "$PRB_4G_RAW" | sed '/^\s*$/d' | wc -l | tr -d ' ')
PRB_5G_ROWS=$(echo "$PRB_5G_RAW" | sed '/^\s*$/d' | wc -l | tr -d ' ')
# event_date가 날짜+시간으로 분리되어 3개 필드로 출력됨: 날짜 시간 count
PRB_4G_SUM=$(echo "$PRB_4G_RAW" | awk '{s+= ($3+0)} END{print s+0}')
PRB_5G_SUM=$(echo "$PRB_5G_RAW" | awk '{s+= ($3+0)} END{print s+0}')

# Determine presence: consider OK if summed counts > 0 for both
if [[ ${PRB_4G_SUM:-0} -ge 1 && ${PRB_5G_SUM:-0} -ge 1 ]]; then
    echo "=> PRB 데이터가 최근 1시간 내에 적재되고 있습니다. [OK]"
else
    echo "=> PRB 데이터 일부 또는 전체가 최근 1시간 내 적재되지 않았습니다. [CRITICAL]"
    echo "   - 4G PRB: ${PRB_4G_SUM:-0} 건 (rows: ${PRB_4G_ROWS:-0})"
    echo "   - 5G PRB: ${PRB_5G_SUM:-0} 건 (rows: ${PRB_5G_ROWS:-0})"
fi

# Print the raw results vertically for readability (shown after judgement)
echo ""
echo "PRB_4G:"
if [[ -z "$(echo "$PRB_4G_RAW" | tr -d '[:space:]')" || "$PRB_4G_ROWS" -eq 0 ]]; then
    echo "  없음"
else
    echo "$PRB_4G_RAW" | sed 's/^/  /'
fi

echo ""
echo "PRB_5G:"
if [[ -z "$(echo "$PRB_5G_RAW" | tr -d '[:space:]')" || "$PRB_5G_ROWS" -eq 0 ]]; then
    echo "  없음"
else
    echo "$PRB_5G_RAW" | sed 's/^/  /'
fi

echo ""
echo "======================================"
echo " PG 연동 (CMSWEB 설정정보) 점검"
echo "======================================"
echo "[1] cmsweb-ftp-server 파드 상태 체크"
pg_cmsweb_pods=$(oc get pod -n nwdaf | grep cmsweb | awk '$3 != "Running" {print $1}')
if [[ -z "$pg_cmsweb_pods" ]]; then
    echo "=> cmsweb-ftp-server-primary(secondary) 파드가 Running 상태입니다. [OK]"
else
    echo "=> Running 상태가 아닌 파드: $pg_cmsweb_pods [CRITICAL]"
fi

# 추가 출력: nwdaf 네임스페이스의 ftp-server 관련 파드 목록 출력
echo ""
ftp_pods_output=$(oc get pod -n nwdaf -l app=ftp-server 2>&1 || true)
if [[ -z "$(echo "$ftp_pods_output" | tr -d '[:space:]')" ]]; then
    echo "  (ftp-server 파드 정보 없음)"
else
    echo "$ftp_pods_output" | sed 's/^/  /'
fi

# echo ""
# echo "[2] cmsweb 기지국 데이터 DB 업데이트 체크"

# # collect raw output, suppress noisy stderr and tolerate failures
# DB_UPD_RAW=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT max(update_time) FROM conn_pgsql_mv_t_cell_lte_all"' 2>/dev/null || true)

# # remove known noise (e.g. 'Defaulted container ...') and use the last non-empty line
# DB_UPD=$(echo "$DB_UPD_RAW" | grep -v 'Defaulted container' | sed -n '/\S/,$p' | tail -n1 | tr -d '\r')
# echo "$DB_UPD"

# if [[ -z "$DB_UPD" ]]; then
#     echo "=> 최근 1시간 내 업데이트 없음 또는 정보 미존재 [CRITICAL]"
# else
#     # DB 시간이 UTC이므로 UTC로 명시하여 파싱
#     DB_EPOCH=$(TZ=UTC date -d "$DB_UPD" +%s 2>/dev/null)

#     if [[ -z "$DB_EPOCH" ]]; then
#         echo "=> 날짜 형식 파싱 오류 [CRITICAL]"
#     else
#         NOW_EPOCH=$(date +%s)
#         ONE_HOUR_AGO=$((NOW_EPOCH - 3600))
#         THREE_HOURS_AGO=$((NOW_EPOCH - 10800))

#         if [[ $DB_EPOCH -ge $ONE_HOUR_AGO ]]; then
#             echo "=> 최근 1시간 내 업데이트 완료 [OK]"
#         elif [[ $DB_EPOCH -ge $THREE_HOURS_AGO ]]; then
#             echo "=> 최근 1~3시간 내 업데이트 [WARNING]"
#         else
#             echo "=> 3시간 이상 미업데이트 또는 정보 미존재 [CRITICAL]"
#         fi
#     fi
# fi

echo ""
echo "[2] cmsweb 기지국 데이터 DB 업데이트 체크"

# LTE 테이블 점검
echo "## LTE 테이블 (conn_pgsql_mv_t_cell_lte_all)"
DB_UPD_RAW=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT max(update_time) FROM conn_pgsql_mv_t_cell_lte_all"' 2>/dev/null || true)
DB_UPD=$(echo "$DB_UPD_RAW" | grep -v 'Defaulted container' | sed -n '/\S/,$p' | tail -n1 | tr -d '\r')
echo "$DB_UPD"

if [[ -z "$DB_UPD" ]]; then
    echo "=> 최근 1시간 내 업데이트 없음 또는 정보 미존재 [CRITICAL]"
else
    DB_EPOCH=$(TZ=UTC date -d "$DB_UPD" +%s 2>/dev/null)
    
    if [[ -z "$DB_EPOCH" ]]; then
        echo "=> 날짜 형식 파싱 오류 [CRITICAL]"
    else
        NOW_EPOCH=$(date +%s)
        ONE_HOUR_AGO=$((NOW_EPOCH - 3600))
        THREE_HOURS_AGO=$((NOW_EPOCH - 10800))
        
        if [[ $DB_EPOCH -ge $ONE_HOUR_AGO ]]; then
            echo "=> 최근 1시간 내 업데이트 완료 [OK]"
        elif [[ $DB_EPOCH -ge $THREE_HOURS_AGO ]]; then
            echo "=> 최근 1~3시간 내 업데이트 [WARNING]"
        else
            echo "=> 3시간 이상 미업데이트 또는 정보 미존재 [CRITICAL]"
        fi
    fi
fi

echo ""
# 5G 테이블 점검
echo "## 5G 테이블 (conn_pgsql_mv_t_cell_5g_all)"
DB_UPD_RAW_5G=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT max(update_time) FROM conn_pgsql_mv_t_cell_5g_all"' 2>/dev/null || true)
DB_UPD_5G=$(echo "$DB_UPD_RAW_5G" | grep -v 'Defaulted container' | sed -n '/\S/,$p' | tail -n1 | tr -d '\r')
echo "$DB_UPD_5G"

if [[ -z "$DB_UPD_5G" ]]; then
    echo "=> 최근 1시간 내 업데이트 없음 또는 정보 미존재 [CRITICAL]"
else
    DB_EPOCH_5G=$(TZ=UTC date -d "$DB_UPD_5G" +%s 2>/dev/null)
    
    if [[ -z "$DB_EPOCH_5G" ]]; then
        echo "=> 날짜 형식 파싱 오류 [CRITICAL]"
    else
        NOW_EPOCH=$(date +%s)
        ONE_HOUR_AGO=$((NOW_EPOCH - 3600))
        THREE_HOURS_AGO=$((NOW_EPOCH - 10800))
        
        if [[ $DB_EPOCH_5G -ge $ONE_HOUR_AGO ]]; then
            echo "=> 최근 1시간 내 업데이트 완료 [OK]"
        elif [[ $DB_EPOCH_5G -ge $THREE_HOURS_AGO ]]; then
            echo "=> 최근 1~3시간 내 업데이트 [WARNING]"
        else
            echo "=> 3시간 이상 미업데이트 또는 정보 미존재 [CRITICAL]"
        fi
    fi
fi


echo ""
echo "======================================"
echo " PG 연동 (QoS 제어) 점검"
echo "======================================"
echo "[1] 제어전송부 Pod  상태 점검"
# 기존 점검 로직 유지: 전체 policysender 파드 목록 및 Running 개수, lease 확인
policysender_all_pods=$(oc get pod -n nwdaf -l app=policysender)
running_count=$(oc get pod -n nwdaf --no-headers 2>/dev/null | awk '/policysender/ && $3 == "Running" {print $1}' | wc -l)
if [[ "$running_count" -eq 2 ]]; then
    echo "=> 2개의 policysender 파드가 Running 상태입니다. [OK]"
elif [[ "$running_count" -eq 1 ]]; then
    echo "=> 1개의 policysender 파드만 Running 상태입니다. [WARNING]"
else
    echo "=> Running 상태의 policysender 파드가 없습니다. [CRITICAL]"
fi

# 전체 policysender 파드 목록 출력 (판별 코멘트 바로 아래 표시)
if [[ -z "$policysender_all_pods" ]]; then
    echo "  (policysender 파드 정보 없음)"
else
    echo "$policysender_all_pods" | sed 's/^/  /'
fi

echo ""
echo "[2] 제어전송부 Active Pod 확인"
# Lease의 holder 값을 Active 파드로 출력 (예: policysender-7b8b7bcdf9-czddn)
lease_holder=$(oc get lease -n nwdaf --no-headers 2>/dev/null | awk '$1=="policysender" {print $2}' || true)
if [[ -n "$lease_holder" ]]; then
    echo "=> Active policysender 파드 (lease holder):"
    echo "  $lease_holder"
    # downstream 로그 점검에서 사용하도록 policysender_pods에 설정
    policysender_pods="$lease_holder"
else
    echo "=> Active policysender 파드가 없습니다. [CRITICAL]"
    policysender_pods=""
fi

echo ""
echo "[3] 제어전송부 실시간 로그 점검"
# 전체 policysender 파드에서 최근 로그를 검사하여
# 판별 기준: `grep -v INFO` 적용 시 남는 로그가 있으면 [WARNING], 없으면 [OK]
policysender_all_names=$(oc get pod -n nwdaf --no-headers 2>/dev/null | awk '/policysender/ {print $1}')
noninfo_found=0
if [[ -n "$policysender_all_names" ]]; then
    for pod in $policysender_all_names; do
        logs_preview=$(oc logs -n nwdaf "$pod" --tail 20 2>/dev/null || true)
        # INFO 라인을 제외했을 때(대문자 INFO만) 남는 내용이 있으면 경고로 판단
        if echo "$logs_preview" | grep -v 'INFO' | sed '/^\s*$/d' | grep -q '.'; then
            noninfo_found=1
            break
        fi
    done
fi

# 판별 코멘트: INFO 이외의 로그 존재 여부로 판단
if [[ "$noninfo_found" -eq 1 ]]; then
    echo "=> 실시간 로그에 INFO 이외의 로그가 존재합니다. [WARNING]"
else
    echo "=> 실시간 로그에 특이사항이 없습니다. [OK]"
fi

# 판별 코멘트 아래에 각 파드별 로그 출력
if [[ -z "$policysender_all_names" ]]; then
    echo "  (policysender 파드 정보 없음)"
else
    for pod in $policysender_all_names; do
        echo "## $pod 로그 출력 (최근 20줄)"
        oc logs -n nwdaf "$pod" --tail 20 2>/dev/null || echo "  (로그를 가져오지 못했습니다)"
        echo "--------------------------------------"
    done
fi

echo ""
echo "[4] 제어전송부 로그 히스토리 전체 점검"
warn_log_all=0
for pod in $policysender_pods; do
    warn_log=$(oc logs -n nwdaf "$pod" | grep -i 'error\|warn' | head -5)
    if [[ -n "$warn_log" ]]; then
        echo "## $pod warn 로그 발견 (최대 5)"
        echo "$warn_log"
        warn_log_all=1
    fi
done
if [[ "$warn_log_all" -eq 0 ]]; then
    echo "=> 모든 policysender 파드에 Error/Warn 로그가 없습니다. [OK]"
else
    echo "=> Error/Warn 로그가 존재하는 policysender 파드가 있습니다. [WARNING]"
fi

echo ""
echo "======================================"
echo " 학습/추론 점검"
echo "======================================"
echo "[1] 파이프라인 Pod 상태 체크"
runof_jobs=$(oc get pod -n nwdaf | grep runof | grep -E 'Error')
if [[ -z "$runof_jobs" ]]; then
    echo "=> 상태값이 Error로 종료된 job이 없습니다. [OK]"
else
    echo "=> Error로 종료된 job이 있습니다. [CRITICAL]"
    echo "$runof_jobs" | sed 's/^/  /'
fi

echo ""
echo "[2] 추론 결과 데이터 적재 상태 체크"

# 2.1) model_type = prb 점검 (prb는 항상 존재해야 함)
PRED_PRB=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT window_end, model_type, count() FROM ai.t_cell_prb_usage_predicted WHERE model_type = '\''prb'\'' AND window_end >= now() - toIntervalMinute(45) GROUP BY window_end, model_type ORDER BY window_end DESC LIMIT 10"' 2>/dev/null || true)
PRED_PRB_ROWS=$(echo "$PRED_PRB" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
# window_end가 날짜+시간으로 분리되어 4개 필드로 출력됨: 날짜 시간 model_type count
PRED_PRB_SUM=$(echo "$PRED_PRB" | awk 'NF>=4 {s+=($4+0)} END{print s+0}')

if [[ -n "$(echo "$PRED_PRB" | tr -d '[:space:]')" && "$PRED_PRB_ROWS" -ge 1 && "$PRED_PRB_SUM" -ge 1 ]]; then
    echo "=> [prb] 추론 결과가 정상적으로 적재되고 있습니다. [OK]"
else
    echo "=> [prb] 추론 결과가 정상적으로 적재되지 않았습니다. [CRITICAL]"
    echo "  (rows: ${PRED_PRB_ROWS:-0}, sum: ${PRED_PRB_SUM:-0})"
fi

# prb 쿼리 결과 출력
if [[ -n "$(echo "$PRED_PRB" | tr -d '[:space:]')" ]]; then
    echo "$PRED_PRB" | sed 's/^/  /'
fi

# 2.2) model_type = lstm 또는 gru 점검 (둘 중 하나가 있으면 OK)
PRED_LG=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT window_end, model_type, count() FROM ai.t_cell_prb_usage_predicted WHERE model_type IN ('\''lstm'\'','\''gru'\'') AND window_end >= now() - toIntervalMinute(5) GROUP BY window_end, model_type ORDER BY window_end DESC LIMIT 30"' 2>/dev/null || true)
# window_end가 날짜+시간으로 분리되어 4개 필드로 출력됨: 날짜 시간 model_type count
PRED_LG_SUM=$(echo "$PRED_LG" | awk 'NF>=4 {s+=($4+0)} END{print s+0}')

# lstm/gru 동시 존재 이슈 탐지 (같은 window_end에 둘 다 존재하면 경고)
PRED_LG_ISSUES=$(echo "$PRED_LG" | awk 'NF>=4 {w=$1" "$2; t=$3; c=$4+0; if(t=="lstm") lstm[w]+=c; else if(t=="gru") gru[w]+=c} END{for(w in lstm){ if((lstm[w]+0)>0 && (gru[w]+0)>0) print w" BOTH_LSTM_GRU"}}')
PRED_LG_ISSUES_CNT=$(echo "$PRED_LG_ISSUES" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')

if [[ "$PRED_LG_SUM" -ge 1 && "$PRED_LG_ISSUES_CNT" -eq 0 ]]; then
    echo "=> [lstm/gru] lstm 또는 gru 중 하나 이상의 결과가 적재되어 있습니다. [OK]"
elif [[ "$PRED_LG_SUM" -ge 1 && "$PRED_LG_ISSUES_CNT" -gt 0 ]]; then
    echo "=> [lstm/gru] lstm/gru 적재에서 충돌(동시 존재)이 발견되었습니다. [WARNING]"
    echo "  세부 이슈:"
    echo "$PRED_LG_ISSUES" | sed 's/^/    /'
else
    echo "=> [lstm/gru] lstm 또는 gru 데이터가 존재하지 않습니다. [CRITICAL]"
fi

# lstm/gru 쿼리 결과 출력
if [[ -n "$(echo "$PRED_LG" | tr -d '[:space:]')" ]]; then
    echo "$PRED_LG" | sed 's/^/  /'
fi

echo ""
echo "[3] 추론용 데이터셋 적재 상태 체크"
INFER_DATA=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT window_end, count() FROM ai.cell_usage_1m_latest WHERE window_end >= now() - toIntervalMinute(2) GROUP BY 1 ORDER BY 1 DESC"')
INFER_ROWS=$(echo "$INFER_DATA" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
if [[ -n "$(echo "$INFER_DATA" | tr -d '[:space:]')" && "$INFER_ROWS" -ge 1 ]]; then
    echo "=> 추론용 데이터셋이 정상적으로 적재되고 있습니다. [OK]"
    echo "$INFER_DATA" | sed 's/^/  /'
else
    echo "=> 추론용 데이터셋이 정상적으로 적재되지 않았습니다. [CRITICAL]"
    echo "  (rows: ${INFER_ROWS:-0})"
    if [[ -n "$(echo "$INFER_DATA" | tr -d '[:space:]')" ]]; then
        echo "$INFER_DATA" | sed 's/^/  /'
    fi
fi

echo ""
echo "[4] 학습용 데이터셋 적재 상태 체크"
TRAIN_DATA=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT window_end, count() FROM ai.cell_usage_hist_5m WHERE window_end >= now() - toIntervalMinute(70) GROUP BY 1 ORDER BY 1 DESC LIMIT 5"')
TRAIN_ROWS=$(echo "$TRAIN_DATA" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
if [[ -n "$(echo "$TRAIN_DATA" | tr -d '[:space:]')" && "$TRAIN_ROWS" -ge 1 ]]; then
    echo "=> 학습용 데이터셋이 정상적으로 적재되고 있습니다. [OK]"
    echo "$TRAIN_DATA" | sed 's/^/  /'
else
    echo "=> 학습용 데이터셋이 정상적으로 적재되지 않았습니다. [CRITICAL]"
    echo "  (rows: ${TRAIN_ROWS:-0})"
    if [[ -n "$(echo "$TRAIN_DATA" | tr -d '[:space:]')" ]]; then
        echo "$TRAIN_DATA" | sed 's/^/  /'
    fi
fi

echo ""
echo "[5] 학습 히스토리 조회"
model_seq_result=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT model_type, excution_end, model_seq, cell_count, train_result FROM ai.model_train_hist ORDER BY model_seq DESC LIMIT 20"' | grep Success)
echo "$model_seq_result" | sed 's/^/  /'

echo ""
echo "======================================"
echo " 모델 히스토리 파일 점검"
echo "======================================"
minio_hist=$(oc exec -n kubeflow minio-nwdaf-0 -- sh -c "mc ls local/model-repo-history")
echo "$minio_hist"
if [[ -z "$minio_hist" ]]; then
    echo "=> 모델 히스토리 파일 미존재 [CRITICAL]"
else
    echo "=> 모델 히스토리 파일 존재 확인 [OK]"
fi

echo ""
echo "======================================"
echo " LSTM 모델 파일 점검"
echo "======================================"
lstm_files=$(oc exec -n kubeflow minio-nwdaf-0 -c minio -- sh -c "mc ls --recursive local/model-repo/lstm_model")
echo "$lstm_files"
if [[ -z "$lstm_files" ]]; then
    echo "=> LSTM 모델 파일 미존재 [CRITICAL]"
else
    most_recent=0
    # 한줄씩 읽으면서 날짜+시간+UTC를 정규표현식으로 파싱
    while read -r line; do
        # 패턴: [2025-07-09 08:03:17 UTC]
        file_dt=$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC')
        ut=$(date -u -d "$file_dt" +%s 2>/dev/null)
        if [[ "$ut" =~ ^[0-9]+$ ]] && [[ -n "$file_dt" ]]; then
            ((ut > most_recent)) && most_recent=$ut
        fi
    done <<<"$lstm_files"
    if (( most_recent == 0 )); then
        echo "=> LSTM 모델 파일 생성시간 파싱 실패 [CRITICAL]"
    else
        echo "=> LSTM 모델 현재 버전 적용시간: $(date -u -d @$most_recent '+%Y-%m-%d %H:%M:%S UTC')"
        echo "=> LSTM 모델 현재 버전: $(oc exec -it -n nwdaf prb-predict-0 -- python ai/Model/version2/exec_get_current_version.py lstm)"
    fi
fi

echo ""
echo "======================================"
echo " GRU 모델 파일 점검"
echo "======================================"
gru_files=$(oc exec -n kubeflow minio-nwdaf-0 -c minio -- sh -c "mc ls --recursive local/model-repo/gru_model")
echo "$gru_files"
if [[ -z "$gru_files" ]]; then
    echo "=> GRU 모델 파일 미존재 [CRITICAL]"
else
    most_recent=0
    # 한줄씩 읽으면서 날짜+시간+UTC를 정규표현식으로 파싱 (LSTM과 동일한 동작)
    while read -r line; do
        # 패턴: [2025-07-09 08:03:17 UTC]
        file_dt=$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC')
        ut=$(date -u -d "$file_dt" +%s 2>/dev/null)
        if [[ "$ut" =~ ^[0-9]+$ ]] && [[ -n "$file_dt" ]]; then
            ((ut > most_recent)) && most_recent=$ut
        fi
    done <<<"$gru_files"
    if (( most_recent == 0 )); then
        echo "=> GRU 모델 파일 생성시간 파싱 실패 [CRITICAL]"
    else
        echo "=> GRU 모델 현재 버전 적용시간: $(date -u -d @$most_recent '+%Y-%m-%d %H:%M:%S UTC')"
        echo "=> GRU 모델 현재 버전: $(oc exec -it -n nwdaf prb-predict-0 -- python ai/Model/version2/exec_get_current_version.py gru)"
    fi
fi

# 5. ClickHouse, MariaDB, PostgreSQL 용량 현황
echo ""
echo "---------- [DB 용량 현황 (ClickHouse, PostgreSQL)] ----------"

# ClickHouse (Pod: clickhouse-local-shard0-0, Namespace: nwdaf)
CLICKHOUSE_NS=nwdaf
CLICKHOUSE_POD=clickhouse-shard0-0
if oc get pod -n $CLICKHOUSE_NS $CLICKHOUSE_POD &>/dev/null; then
  echo ""
  echo "[ClickHouse 테이블스페이스 사용량]"
  clickhouse_space=$(oc exec -n $CLICKHOUSE_NS $CLICKHOUSE_POD -- bash -c \
    "clickhouse-client --password=\$CLICKHOUSE_ADMIN_PASSWORD --query \"
    SELECT
      database,
      formatReadableSize(sum(bytes)) AS used,
      any(disk_name) AS disk
    FROM system.parts
    WHERE active
    GROUP BY database
    ORDER BY sum(bytes) DESC;
    \" 2>/dev/null")
  echo "$clickhouse_space" | column -t
  if [[ $(echo "$clickhouse_space" | grep -i 'used' | awk '{print $2}' | sed 's/GiB//g') -gt 100 ]]; then
    echo "=> ClickHouse 사용량 100GiB 초과 [WARNING]"
  else
    echo "=> 테이블스페이스 사용량 정상 [OK]"
  fi

  echo ""
  echo "[ClickHouse 디스크 여유 공간]"
  clickhouse_disk=$(oc exec -n $CLICKHOUSE_NS $CLICKHOUSE_POD -- bash -c \
    "clickhouse-client --password=\$CLICKHOUSE_ADMIN_PASSWORD --query \"
    SELECT
      name AS disk_name,
      path,
      formatReadableSize(free_space) AS free_space,
      formatReadableSize(total_space) AS total_space
    FROM system.disks;
    \" 2>/dev/null")
  echo "$clickhouse_disk" | column -t
  # 여유 공간 판정 예시
  free_space=$(echo "$clickhouse_disk" | awk '/free_space/ {getline; print $3}' | sed 's/GiB//g')
  if [[ "$free_space" != "" && "$free_space" -lt 50 ]]; then
    echo "=> ClickHouse 디스크 여유 공간 50GiB 미만 [WARNING]"
  else
    echo "=> ClickHouse 디스크 여유 공간 충분 [OK]"
  fi
else
  echo "[ClickHouse Pod를 찾을 수 없습니다.] [CRITICAL]"
fi


# # MariaDB (Namespace: kubeflow, 패스워드 없이 접속)
# MARIADB_NS=kubeflow
# MARIADB_POD=$(oc get pod -n $MARIADB_NS --no-headers | grep -E 'mariadb|mysql' | awk 'NR==1{print $1}')
# if [ -n "$MARIADB_POD" ]; then
#     echo ""
#     echo "[MariaDB 데이터베이스 용량]"
#     # mysql -sN: 헤더 없이 탭으로 구분된 결과를 출력하므로 파싱이 쉬워짐
#     mariadb_space=$(oc exec -n $MARIADB_NS $MARIADB_POD -- mysql -sN -uroot -e "
#         SELECT table_schema AS db_name,
#                      ROUND(SUM(data_length + index_length)/1024/1024,2) AS used_MB
#         FROM information_schema.tables
#         GROUP BY table_schema
#         ORDER BY used_MB DESC;
#     " 2>/dev/null)

#     # 보기 좋게 정렬 출력 (탭 구분자 사용)
#     echo "$mariadb_space" | column -t -s $'\t'

#     # 전체 DB 사용량 합계: SQL에서 직접 계산하여 반환받음 (더 정확함)
#     total_used_mb=$(oc exec -n $MARIADB_NS $MARIADB_POD -- mysql -sN -uroot -e "
#         SELECT ROUND(SUM(data_length + index_length)/1024/1024,2) AS total_used_MB
#         FROM information_schema.tables;
#     " 2>/dev/null)

#     # NULL 또는 빈 문자열 대비
#     if [[ -z "$total_used_mb" || "$total_used_mb" == "NULL" ]]; then
#         total_used_mb=0
#     fi

#     # 포맷 보장 (소수점 둘째자리)
#     total_used_mb=$(printf "%.2f" "$total_used_mb")

#     echo "=> MariaDB 전체 DB 사용량 합계: ${total_used_mb} MB"

#     # 20480MB 초과 체크 (부동 소수점 비교)
#     if awk -v t="$total_used_mb" 'BEGIN{ if ((t+0) > 20480) exit 0; else exit 1 }'; then
#             echo "=> MariaDB DB 사용량 20480MB 초과 [WARNING]"
#     else
#             echo "=> MariaDB DB 용량 정상 [OK]"
#     fi
# else
#   echo "[MariaDB Pod를 찾을 수 없습니다.] [CRITICAL]"
# fi

# PostgreSQL (Namespace: nwdaf, Pod명: cloudnative-pg-cluster)
POSTGRES_NS=nwdaf
POSTGRES_POD=$(oc get pod -n $POSTGRES_NS --no-headers | grep cloudnative-pg-cluster | awk 'NR==1{print $1}')
if [ -n "$POSTGRES_POD" ]; then
  echo ""
  echo "[PostgreSQL 데이터베이스 용량]"
  postgres_space=$(oc exec -n $POSTGRES_NS $POSTGRES_POD -- psql -U postgres -c "
    SELECT datname AS db_name,
           pg_size_pretty(pg_database_size(datname)) AS used
    FROM pg_database
    ORDER BY pg_database_size(datname) DESC;
  " 2>/dev/null)
  echo "$postgres_space" | column -t
  # 1GB 이상 사용 판정 예시
  if [[ $(echo "$postgres_space" | grep -Eo '[0-9\.]+GB' | sed 's/GB//g' | awk '{if($1>1) print $1}' | wc -l) -ge 1 ]]; then
    echo "=> PostgreSQL DB 사용량 1GB 초과 [WARNING]"
  else
    echo "=> PostgreSQL DB 용량 정상 [OK]"
  fi
else
  echo "[PostgreSQL Pod를 찾을 수 없습니다.] [CRITICAL]"
fi

# MPS 점검 항목 추가 : 2026-02

echo ""
echo "======================================"
echo " MPS 기능 점검"
echo "======================================"
echo "[1] MPS 논리 GPU 수 확인"
# 점검할 노드 지정 (패턴으로 자동 검색, 실패시 기존 하드코드 사용)
NODE_PATTERN="nwdaf-wk03.ocp"
DEFAULT_NODE="snsu-5g21b-nwdaf-wk03.ocp21.skt.local"
# oc get nodes 출력에서 이름 추출 후 패턴 매칭
NODE=$(oc get nodes --no-headers 2>/dev/null | awk '{print $1}' | grep "$NODE_PATTERN" | head -n1)
if [[ -z "$NODE" ]]; then
    NODE="$DEFAULT_NODE"
    echo "대상 노드를 자동 검색하지 못해 기본값 사용: $NODE"
else
    echo "대상 노드 자동 선택: $NODE"
fi

allocatable_block=$(oc describe node "$NODE" 2>/dev/null | awk '
    /Allocatable:/ {print; flag=1; next}
    flag {
        if ($0 ~ /^[[:space:]]+/) { print; next }
        else exit
    }
')

# nvidia.com/gpu 값 추출 및 검사 (판별 코멘트를 먼저 출력)
gpu_val=$(echo "$allocatable_block" | awk -F: '/nvidia.com\/gpu/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')
if [[ -z "$gpu_val" ]]; then
    echo "=> nvidia.com/gpu 항목을 찾을 수 없습니다. [CRITICAL]"
else
    gpu_val_trim=$(echo "$gpu_val" | tr -d '[:space:]')
    if [[ "$gpu_val_trim" == "2" ]]; then
        echo "=> nvidia.com/gpu: $gpu_val_trim 로 정상 확인됨 [OK]"
    else
        echo "=> nvidia.com/gpu: $gpu_val_trim 로 확인 필요! [CRITICAL]"
    fi
fi

# 이후에 원본 Allocatable 블록(로그)을 출력
if [[ -z "$allocatable_block" ]]; then
    echo ""
    echo "=> Allocatable 정보를 가져오지 못했습니다: $NODE"
else
    echo ""
    echo "$allocatable_block"
fi

# device-plugin 데몬셋 및 mps-control 데몬 상태 검사
echo ""
echo "[2] MPS 관련 파드 상태 점검"
check_pods() {
    local label=$1
    local desc=$2
    pods=$(oc get pod -n gpu-operator -l "$label" --no-headers 2>/dev/null)
    if [[ -z "$pods" ]]; then
        echo "=> $desc 파드를 찾을 수 없습니다. [CRITICAL]"
        return
    fi

    local overall_ok=1
    local pod_lines=()

    # 각 파드 줄: NAME READY STATUS RESTARTS AGE
    while read -r name ready status rest; do
        if [[ "$ready" =~ ^([0-9]+)/([0-9]+)$ ]]; then
            num=${BASH_REMATCH[1]}; den=${BASH_REMATCH[2]}
        else
            num=0; den=1
        fi

        if [[ "$num" -eq "$den" && "$status" == "Running" ]]; then
            pod_lines+=("  - $name READY:$ready STATUS:$status")
        else
            pod_lines+=("  - $name READY:$ready STATUS:$status [CRITICAL]")
            overall_ok=0
        fi
    done <<< "$pods"

    if [[ $overall_ok -eq 1 ]]; then
        echo "=> $desc 상태 점검 결과 [OK]"
    else
        echo "=> $desc 상태 점검 결과 [CRITICAL]"
    fi

    for line in "${pod_lines[@]}"; do
        echo "$line"
    done
    echo ""
}

check_pods "app=nvidia-device-plugin-daemonset" "nvidia-device-plugin-daemonset"
check_pods "app=nvidia-device-plugin-mps-control-daemon" "nvidia-device-plugin-mps-control-daemon"

echo "======================================"
echo " 점검 완료"
echo "======================================"
# 실행종료 시각 출력 (KST)
EXEC_TIME_KST=$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S %Z')
echo "실행 종료 (KST): $EXEC_TIME_KST"
echo ""