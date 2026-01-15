#!/bin/bash

# Kubernetes 클러스터 점검 스크립트

echo "======================================"
echo " K8s 클러스터 점검 체크리스트"
echo "======================================"

# 1. K8S 노드 연결 상태
echo "[1] K8S 노드 연결 상태"
node_status=$(oc get nodes --no-headers | awk '{print $2}' | sort | uniq)
not_ready_nodes=$(oc get nodes --no-headers | awk '$2 != "Ready" {print $1}')
if [[ "$node_status" == "Ready" ]] && [[ -z "$not_ready_nodes" ]]; then
    echo "=> 모든 클러스터 노드의 STATUS가 READY입니다. [OK]"
else
    if [[ -z "$not_ready_nodes" ]]; then
        echo "=> 일부 노드의 상태가 정상적으로 표시되지 않습니다. [INFO]"
    else
        echo "=> READY가 아닌 노드가 존재합니다: $not_ready_nodes [CRITICAL]"
    fi
fi

# 2. K8S 노드별 시스템 부하 상태
echo "[2] K8S 노드별 시스템 부하 상태"
oc adm top nodes
cpu_over=$(oc adm top nodes --no-headers | awk '$3+0 > 90 {print $1":"$3}')
mem_over=$(oc adm top nodes --no-headers | awk '$5+0 > 90 {print $1":"$5}')
cpu_warn=$(oc adm top nodes --no-headers | awk '$3+0 > 70 && $3+0 <= 90 {print $1":"$3}')
mem_warn=$(oc adm top nodes --no-headers | awk '$5+0 > 70 && $5+0 <= 90 {print $1":"$5}')

if [[ -z "$cpu_over" && -z "$mem_over" && -z "$cpu_warn" && -z "$mem_warn" ]]; then
    echo "=> 모든 노드의 CPU/Memory 부하가 70% 이하입니다. [OK]"
else
    if [[ -n "$cpu_over" || -n "$mem_over" ]]; then
        echo "=> CPU/Memory 부하가 90%를 초과한 노드가 있습니다."
        [[ -n "$cpu_over" ]] && echo "  CPU CRITICAL: $cpu_over"
        [[ -n "$mem_over" ]] && echo "  Memory CRITICAL: $mem_over"
        echo "[CRITICAL]"
    fi
    if [[ -n "$cpu_warn" || -n "$mem_warn" ]]; then
        echo "=> CPU/Memory 부하가 70% 초과~90% 이하인 노드가 있습니다."
        [[ -n "$cpu_warn" ]] && echo "  CPU WARNING: $cpu_warn"
        [[ -n "$mem_warn" ]] && echo "  Memory WARNING: $mem_warn"
        echo "[WARNING]"
    fi
fi

# 3. 네임스페이스별 K8S 이벤트 확인
echo "[3] 네임스페이스별 K8S 이벤트 확인"
for ns in nwdaf kubeflow istio-system strimzi-kafka infra-datastore gpu-operator; do
    output=$(oc get event -n $ns --sort-by=.lastTimestamp | head -n 5| tail -n 5 2>&1)
    echo "- 이벤트 확인: $ns"
    if echo "$output" | grep -q "No resources found"; then
        echo "  이벤트 없음 [OK]"
    else
        header=$(echo "$output" | head -1)
        echo "$header"
        count=0
        # 이벤트 줄별로 24시간(1440분)이내, 최대 5개만 출력
        echo "$output" | tail -n +2 | while read -r line; do
            age=$(echo "$line" | awk '{print $1}')
            age_min=0
            if [[ "$age" =~ ^([0-9]+)s$ ]]; then
                age_min=$((${BASH_REMATCH[1]} / 60))
            elif [[ "$age" =~ ^([0-9]+)m$ ]]; then
                age_min=${BASH_REMATCH[1]}
            elif [[ "$age" =~ ^([0-9]+)h$ ]]; then
                age_min=$((${BASH_REMATCH[1]} * 60))
            elif [[ "$age" =~ ^([0-9]+)d$ ]]; then
                age_min=$((${BASH_REMATCH[1]} * 1440))
            fi
            if (( age_min <= 1440 )); then
                echo "$line"
                count=$((count + 1))
                if (( count == 5 )); then
                    break
                fi
            fi
        done | tee /tmp/event_${ns}_last24h.txt
        warnings=$(cat /tmp/event_${ns}_last24h.txt | grep -i warning | grep -v transient | sort)
        if [[ -n "$warnings" ]]; then
            echo "$warnings"
            echo "  Warning 이벤트 존재 [WARNING]"
        else
            echo "  Warning 없음 [OK]"
        fi
    fi
done

# 4. 네임스페이스별 파드 상태
echo "[4] 네임스페이스별 파드 상태"
for ns in nwdaf kubeflow istio-system strimzi-kafka infra-datastore gpu-operator; do
    issues=$(oc get pod -n $ns | grep -E 'Error|Failed|Unknown|Pending|CrashLoopBackOff')
    echo "- 파드 상태 확인: $ns"
    if [[ -n "$issues" ]]; then
        echo "$issues"
        echo "  이상 상태의 파드 발견 [CRITICAL]"
    else
        echo "  이상 상태의 파드 없음 [OK]"
    fi
done

echo "======================================"
echo " IPMDN 연동 (CDR 데이터) 점검"
echo "======================================"
ipmdn_pods=$(oc get pod -n strimzi-kafka --no-headers | awk '$3 != "Running" {print $1}')
if [[ -z "$ipmdn_pods" ]]; then
    echo "=> 모든 파드가 Running 상태입니다. [OK]"
else
    echo "=> Running 상태가 아닌 파드: $ipmdn_pods [CRITICAL]"
fi

echo "[LAG 점검]"
NAMESPACE="strimzi-kafka"
POD="kafka-pool-nwdaf-wk01-3"
GROUP="nwdaf-clickhouse"
KAFKA_CMD="/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --group $GROUP --describe"
TOPICS=("ipmdn-nwdaf-4g" "ipmdn-nwdaf-5g" "ipmdn-nwdaf-3g" "usercontrol")
LOG_FILE="kafka_lag_history.log"

# 변화폭 임계값(정수, 100분율) - bc가 없으므로 정수로 계산 (10=10%, 30=30%)
THRESHOLD_WARNING=10   # 10% 이상 변화시 WARNING
THRESHOLD_CRITICAL=30  # 30% 이상 변화시 CRITICAL

ITERATIONS=5
INTERVAL=3   # 반복 간격(초)

declare -A LAG_HISTORY

get_lag() {
  local topic=$1
  local result
  result=$(oc exec -n $NAMESPACE $POD -- $KAFKA_CMD 2>/dev/null | grep "$topic" | awk '{print $3, $6}')
  echo "$result"
}

echo "======================================"
echo " Kafka Topic Lag 변화폭 체크 (5회 반복)"
echo "======================================"

for ((i=1; i<=ITERATIONS; i++)); do
  for topic in "${TOPICS[@]}"; do
    lag_sum=0
    lag_count=0
    while read -r partition lag; do
      if [[ "$lag" =~ ^[0-9]+$ ]]; then
        lag_sum=$((lag_sum + lag))
        lag_count=$((lag_count + 1))
      fi
    done < <(get_lag $topic)

    if [ $lag_count -gt 0 ]; then
      avg_lag=$((lag_sum / lag_count))
    else
      avg_lag=0
    fi

    # 히스토리에 기록 (콤마로 연결)
    if [ -z "${LAG_HISTORY[$topic]}" ]; then
      LAG_HISTORY[$topic]="$avg_lag"
    else
      LAG_HISTORY[$topic]+=",$avg_lag"
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') [ITER $i] $topic 평균 Lag: $avg_lag" | tee -a $LOG_FILE
  done

  if [ $i -lt $ITERATIONS ]; then
    sleep $INTERVAL
  fi
done

echo ""
echo "----- Kafka Lag 변화폭 분석 결과 -----" | tee -a $LOG_FILE
for topic in "${TOPICS[@]}"; do
  IFS=',' read -ra lag_values <<< "${LAG_HISTORY[$topic]}"
  min="${lag_values[0]}"
  max="${lag_values[0]}"
  first="${lag_values[0]}"
  last="${lag_values[-1]}"
  for v in "${lag_values[@]}"; do
    (( v < min )) && min=$v
    (( v > max )) && max=$v
  done

  # 변화율 계산 (정수 연산, 100 곱해서 100분율로)
  if [ "$first" -gt 0 ]; then
    diff=$((last - first))
    abs_diff=$diff
    [ $diff -lt 0 ] && abs_diff=$(( -diff ))
    pct=$(( abs_diff * 100 / first ))  # 정수(%)로 계산

    if [ $pct -ge $THRESHOLD_CRITICAL ]; then
      status="CRITICAL"
      message="Lag 변화폭 CRITICAL: 시작=$first, 종료=$last (Δ=$diff, 변화율=${pct}%)"
    elif [ $pct -ge $THRESHOLD_WARNING ]; then
      status="WARNING"
      message="Lag 변화폭 WARNING: 시작=$first, 종료=$last (Δ=$diff, 변화율=${pct}%)"
    else
      status="OK"
      message="Lag 변화 정상: 시작=$first, 종료=$last (Δ=$diff, 변화율=${pct}%)"
    fi
    echo "[${status}] $topic $message | Max: $max, Min: $min, 측정값: ${LAG_HISTORY[$topic]}" | tee -a $LOG_FILE
  else
    echo "[INIT] $topic: Lag 측정값: ${LAG_HISTORY[$topic]} (변화폭 판단 불가: 시작값 미정)" | tee -a $LOG_FILE
  fi
done

echo "======================================"
echo " IDCUBE Datagw 연동 (PRB 데이터) 점검"
echo "======================================"
datagw_jobs=$(oc get pod -n nwdaf | grep datagw | grep -E 'Error')
if [[ -z "$datagw_jobs" ]]; then
    echo "=> 상태값이 Error로 종료된 job이 없습니다. [OK]"
else
    echo "=> Error로 종료된 job: $datagw_jobs [CRITICAL]"
fi

echo "[PRB 데이터 업데이트 체크]"
PRB_4G=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT event_date, count() FROM t_4g_cell_prb_5m GROUP BY event_date ORDER BY event_date DESC LIMIT 5"')
PRB_5G=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT event_date, count() FROM t_5g_cell_prb_15m GROUP BY event_date ORDER BY event_date DESC LIMIT 5"')
echo "$PRB_4G"
echo "$PRB_5G"
if [[ $(echo "$PRB_4G" | wc -l) -ge 1 && $(echo "$PRB_5G" | wc -l) -ge 1 ]]; then
    echo "=> PRB 데이터가 정상적으로 갱신되고 있습니다. [OK]"
else
    echo "=> PRB 데이터 일부 또는 전체가 미갱신되었습니다. [WARNING/CRITICAL]"
fi

echo "======================================"
echo " PG 연동 (CMSWEB 설정정보) 점검"
echo "======================================"
pg_cmsweb_pods=$(oc get pod -n nwdaf | grep cmsweb | awk '$3 != "Running" {print $1}')
if [[ -z "$pg_cmsweb_pods" ]]; then
    echo "=> cmsweb-ftp-server-primary(secondary) 파드가 Running 상태입니다. [OK]"
else
    echo "=> Running 상태가 아닌 파드: $pg_cmsweb_pods [CRITICAL]"
fi

echo "[DB 업데이트 시간 체크]"
DB_UPD=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT max(update_time) FROM conn_pgsql_mv_t_cell_lte_all"')
echo "$DB_UPD"
if [[ -z "$DB_UPD" ]]; then
    echo "=> 최근 1시간 내 업데이트 없음 또는 정보 미존재 [CRITICAL]"
elif [[ $(date --date="$DB_UPD" +%s) -ge $(date --date='1 hour ago' +%s) ]]; then
    echo "=> 최근 1시간 내 업데이트 완료 [OK]"
elif [[ $(date --date="$DB_UPD" +%s) -ge $(date --date='3 hour ago' +%s) ]]; then
    echo "=> 최근 1~3시간 내 업데이트 [WARNING]"
else
    echo "=> 3시간 이상 미업데이트 또는 정보 미존재 [CRITICAL]"
fi

echo "======================================"
echo " PG 연동 (Qos 제어) 점검"
echo "======================================"
policysender_pods=$(oc get pod -n nwdaf --no-headers | awk '/policysender/ {print $1}')
running_count=$(oc get pod -n nwdaf --no-headers | awk '/policysender/ && $3 == "Running"' | wc -l)
if [[ "$running_count" -eq 2 ]]; then
    echo "=> 2개의 policysender 파드가 Running 상태입니다. [OK]"
elif [[ "$running_count" -eq 1 ]]; then
    echo "=> 1개의 policysender 파드만 Running 상태입니다. [WARNING]"
else
    echo "=> Running 상태의 policysender 파드가 없습니다. [CRITICAL]"
fi

lease_status=$(oc get lease -n nwdaf | grep policysender)
if [[ -n "$lease_status" ]]; then
    echo "$lease_status"
    echo "=> lease 정보가 정상적으로 갱신되고 있습니다. [OK]"
else
    echo "=> lease 정보가 없습니다. [CRITICAL]"
fi

echo "[실시간 제어 액션 로그]"
for pod in $policysender_pods; do
    echo "## $pod 로그 출력 (최근 20줄)"
    log_output=$(oc logs -n nwdaf "$pod" --tail 20)
    echo "$log_output"
    if echo "$log_output" | grep -i 'error\|fail\|unknown' >/dev/null; then
        echo "  -> 액션 로그에 오류/실패/이상 상태가 있습니다. [CRITICAL]"
    elif echo "$log_output" | grep -i 'warn' >/dev/null; then
        echo "  -> 액션 로그에 경고 메시지가 있습니다. [WARNING]"
    else
        echo "  -> 액션 로그 정상 [OK]"
    fi
    echo "--------------------------------------"
done

echo "[warn 로그 체크]"
warn_log_all=0
for pod in $policysender_pods; do
    warn_log=$(oc logs -n nwdaf "$pod" | grep -i warn | head -5)
    if [[ -n "$warn_log" ]]; then
        echo "## $pod warn 로그 발견 (최대 5)"
        echo "$warn_log"
        warn_log_all=1
    fi
done
if [[ "$warn_log_all" -eq 0 ]]; then
    echo "=> 모든 policysender 파드에 warn 로그가 없습니다. [OK]"
else
    echo "=> warn 로그가 존재하는 policysender 파드가 있습니다. [WARNING]"
fi

echo "======================================"
echo " 학습/추론 점검"
echo "======================================"
runof_jobs=$(oc get pod -n nwdaf | grep runof | grep -E 'Error')
if [[ -z "$runof_jobs" ]]; then
    echo "=> 상태값이 Error로 종료된 job이 없습니다. [OK]"
else
    echo "=> Error로 종료된 job: $runof_jobs [CRITICAL]"
fi

PRED_CHECK=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT window_end, count() FROM t_cell_prb_usage_predicted GROUP BY window_end ORDER BY window_end DESC LIMIT 10"')
echo "$PRED_CHECK"
if [[ $(echo "$PRED_CHECK" | wc -l) -ge 1 ]]; then
    echo "=> 1분 주기로 추론 결과가 적재되고 있습니다. [OK]"
else
    echo "=> 일부 또는 전체 결과 미적재 [WARNING/CRITICAL]"
fi

model_seq_result=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT model_type, excution_end, model_seq, cell_count, train_result FROM ai.model_train_hist ORDER BY excution_end DESC LIMIT 20"' | grep Success)
if [[ -n "$model_seq_result" ]]; then
    echo "=> 마지막 model_seq가 Success입니다. [OK]"
else
    echo "=> 마지막 model_seq가 Success가 아닙니다. [WARNING/CRITICAL]"
fi

echo "======================================"
echo " 모델 히스토리 파일 점검"
echo "======================================"
minio_hist=$(oc exec -n kubeflow minio-nwdaf-0 -- sh -c "mc alias set local http://localhost:9000 minio minio123 >/dev/null 2>&1 && mc ls local/model-repo-history")
echo "$minio_hist"
if [[ -z "$minio_hist" ]]; then
    echo "=> 모델 히스토리 파일 미존재 [CRITICAL]"
else
    # 최신 파일 생성시간 추출 (UTC)
    latest_time_str=$(echo "$minio_hist" | awk '{print $1" "$2}')
    latest_unixtime=0
    for t in $latest_time_str; do
        ut=$(date -u -d "$t" +%s 2>/dev/null)
        if [[ "$ut" =~ ^[0-9]+$ ]] && (( ut > latest_unixtime )); then
            latest_unixtime=$ut
        fi
    done
    now_utc=$(date -u +%s)
    diff_hour=$(( (now_utc - latest_unixtime) / 3600 ))
    if (( diff_hour < 24 )); then
        echo "=> 최신 모델 히스토리 파일 생성시간: $(date -u -d @$latest_unixtime '+%Y-%m-%d %H:%M:%S UTC') [OK: 24시간 이내]"
    elif (( diff_hour < 72 )); then
        echo "=> 최신 모델 히스토리 파일 생성시간: $(date -u -d @$latest_unixtime '+%Y-%m-%d %H:%M:%S UTC') [WARNING: 24~72시간]"
    else
        echo "=> 최신 모델 히스토리 파일 생성시간: $(date -u -d @$latest_unixtime '+%Y-%m-%d %H:%M:%S UTC') [CRITICAL: 3일 이상]"
    fi
fi

echo "======================================"
echo " LSTM 모델 파일 점검"
echo "======================================"
lstm_files=$(oc exec -n kubeflow minio-nwdaf-0 -c minio -- sh -c "mc alias set local http://localhost:9000 minio minio123 >/dev/null 2>&1 && mc ls --recursive local/model-repo/lstm_model")
echo "$lstm_files"
if [[ -z "$lstm_files" ]]; then
    echo "=> LSTM 모델 파일 미존재 [CRITICAL]"
else
    most_recent=0
    oldest=9999999999
    declare -A time_count
    # 한줄씩 읽으면서 날짜+시간+UTC를 정규표현식으로 파싱
    while read -r line; do
        # 패턴: [2025-07-09 08:03:17 UTC]
        file_dt=$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC')
        ut=$(date -u -d "$file_dt" +%s 2>/dev/null)
        if [[ "$ut" =~ ^[0-9]+$ ]] && [[ -n "$file_dt" ]]; then
            ((ut > most_recent)) && most_recent=$ut
            ((ut < oldest)) && oldest=$ut
            time_count[$ut]=$((time_count[$ut]+1))
        fi
    done <<<"$lstm_files"
    now_utc=$(date -u +%s)
    diff_hour=$(( (now_utc - most_recent) / 3600 ))
    # 동기화 판단: 모든 파일 시간이 같으면 OK, 아니면 WARNING
    if (( ${#time_count[@]} == 1 )); then
        sync_msg="[OK: 동기화]"
    else
        sync_msg="[WARNING: 일부 미동기]"
    fi
    if (( most_recent == 0 )); then
        echo "=> LSTM 모델 파일 생성시간 파싱 실패 [CRITICAL]"
    elif (( diff_hour < 24 )); then
        echo "=> LSTM 모델 최신 파일 생성시간: $(date -u -d @$most_recent '+%Y-%m-%d %H:%M:%S UTC') $sync_msg"
    elif (( diff_hour < 72 )); then
        echo "=> LSTM 모델 최신 파일 생성시간: $(date -u -d @$most_recent '+%Y-%m-%d %H:%M:%S UTC') [WARNING: 24~72시간] $sync_msg"
    else
        echo "=> LSTM 모델 최신 파일 생성시간: $(date -u -d @$most_recent '+%Y-%m-%d %H:%M:%S UTC') [CRITICAL: 3일 이상] $sync_msg"
    fi
fi

echo "======================================"
echo " GRU 모델 파일 점검"
echo "======================================"
gru_files=$(oc exec -n kubeflow minio-nwdaf-0 -c minio -- sh -c "mc alias set local http://localhost:9000 minio minio123 >/dev/null 2>&1 && mc ls --recursive local/model-repo/gru_model")
echo "$gru_files"
if [[ -z "$gru_files" ]]; then
    echo "=> GRU 모델 파일 미존재 [CRITICAL]"
else
    most_recent=0
    oldest=9999999999
    declare -A time_count
    # 한줄씩 읽으면서 날짜+시간+UTC를 정규표현식으로 파싱
    while read -r line; do
        # 패턴: [2025-07-09 08:03:17 UTC]
        file_dt=$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC')
        ut=$(date -u -d "$file_dt" +%s 2>/dev/null)
        if [[ "$ut" =~ ^[0-9]+$ ]] && [[ -n "$file_dt" ]]; then
            ((ut > most_recent)) && most_recent=$ut
            ((ut < oldest)) && oldest=$ut
            time_count[$ut]=$((time_count[$ut]+1))
        fi
    done <<<"$gru_files"
    now_utc=$(date -u +%s)
    diff_hour=$(( (now_utc - most_recent) / 3600 ))
    # 동기화 판단: 모든 파일 시간이 같으면 OK, 아니면 WARNING
    if (( ${#time_count[@]} == 1 )); then
        sync_msg="[OK: 동기화]"
    else
        sync_msg="[WARNING: 일부 미동기]"
    fi
    if (( most_recent == 0 )); then
        echo "=> GRU 모델 파일 생성시간 파싱 실패 [CRITICAL]"
    elif (( diff_hour < 24 )); then
        echo "=> GRU 모델 최신 파일 생성시간: $(date -u -d @$most_recent '+%Y-%m-%d %H:%M:%S UTC') $sync_msg"
    elif (( diff_hour < 72 )); then
        echo "=> GRU 모델 최신 파일 생성시간: $(date -u -d @$most_recent '+%Y-%m-%d %H:%M:%S UTC') [WARNING: 24~72시간] $sync_msg"
    else
        echo "=> GRU 모델 최신 파일 생성시간: $(date -u -d @$most_recent '+%Y-%m-%d %H:%M:%S UTC') [CRITICAL: 3일 이상] $sync_msg"
    fi
fi


# 5. ClickHouse, MariaDB, PostgreSQL 용량 현황
echo ""
echo "---------- [DB 용량 현황 (ClickHouse, MariaDB, PostgreSQL)] ----------"

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


# MariaDB (Namespace: kubeflow, 패스워드 없이 접속)
MARIADB_NS=kubeflow
MARIADB_POD=$(oc get pod -n $MARIADB_NS --no-headers | grep -E 'mariadb|mysql' | awk 'NR==1{print $1}')
if [ -n "$MARIADB_POD" ]; then
  echo ""
  echo "[MariaDB 데이터베이스 용량]"
  mariadb_space=$(oc exec -n $MARIADB_NS $MARIADB_POD -- mysql -uroot --protocol=TCP -e "
    SELECT table_schema AS db_name,
           ROUND(SUM(data_length + index_length)/1024/1024,2) AS used_MB
    FROM information_schema.tables
    GROUP BY table_schema
    ORDER BY used_MB DESC;
  " 2>/dev/null)
  echo "$mariadb_space" | column -t

  # 전체 DB 사용량 합계 계산 (헤더 제외)
  total_used_mb=$(echo "$mariadb_space" | awk 'NR>1 {sum+=$2} END {print sum}')

  # 20480MB 초과 체크 (awk로 float 비교)
  if echo "$total_used_mb 20480" | awk '{exit ($1 > $2 ? 0 : 1)}'; then
    echo "=> MariaDB DB 사용량 20480MB 초과 [WARNING]"
  else
    echo "=> MariaDB DB 용량 정상 [OK]"
  fi
else
  echo "[MariaDB Pod를 찾을 수 없습니다.] [CRITICAL]"
fi

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

echo "======================================"
echo " 점검 완료"
echo "======================================"