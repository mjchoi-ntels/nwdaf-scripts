#!/bin/bash

# Guard: require oc login as nwdaf-admin
current_user=$(oc whoami 2>/dev/null || echo "")
if [ "$current_user" != "nwdaf-admin" ]; then
    echo "현재 로그인된 계정은 '$current_user' — 권한이 있는 계정으로 로그인해주세요. 종료합니다." >&2
    exit 1
fi

set -euo pipefail

# 전역 결과 배열 선언
declare -a CHECK_RESULTS=()

# 실행일시 출력 (KST)
EXEC_TIME_KST=$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S %Z')
echo ""
echo "======================================"
echo " K8s 클러스터 점검 체크리스트"
echo "======================================"
echo "실행일시 (KST): $EXEC_TIME_KST"

# CLI argument handling: if no args supplied -> run all checks.
# If args are given, they select which checks to run. Accepts numbers (1..9)
# or names: nodes,node_load,events,pods,kafka,prb,pg,ai,db_disk
SELECTED_KEYS=()
SELECT_ALL=1
if [[ $# -gt 0 ]]; then
    SELECT_ALL=0
    while [[ $# -gt 0 ]]; do
        a=$(echo "$1" | tr '[:upper:]' '[:lower:]')
        case "$a" in
            1|nodes|node)
                SELECTED_KEYS+=("1") ;;
            2|node_load|load)
                SELECTED_KEYS+=("2") ;;
            3|events|namespace_events)
                SELECTED_KEYS+=("3") ;;
            4|pods|namespace_pods)
                SELECTED_KEYS+=("4") ;;
            5|kafka|ipmdn)
                SELECTED_KEYS+=("5") ;;
            6|prb)
                SELECTED_KEYS+=("6") ;;
            7|cmsweb)
                SELECTED_KEYS+=("7") ;;
            8|policysender|ps|pg)
                SELECTED_KEYS+=("8") ;;
            9|ai|ml)
                SELECTED_KEYS+=("9") ;;
            10|db_disk|dbdisk|database|disk)
                SELECTED_KEYS+=("10") ;;
            11|ui|ui_check|web|webui)
                SELECTED_KEYS+=("11") ;;
                        -h|--help)
                                cat <<'USAGE'
Usage: nwdaf-check-v2.sh [checks...]

Description:
    Run NDWAF operational checks against the OpenShift cluster. Without arguments
    the script runs all checks. When one or more arguments are provided, only
    the selected checks run.

Checks (number or name):
    1  | nodes         : Node status (Ready/NotReady)
    2  | node_load     : Node CPU/Memory usage (adm top nodes)
    3  | events        : Namespace events (warnings/errors)
    4  | pods          : Namespace pod status and recent pods list
    5  | kafka         : Kafka controller/broker/consumer lag and CDR load
    6  | prb           : PRB/Datagw ingestion and recent counts
    7  | cmsweb        : CMSWEB FTP server and base station data checks
    8  | policysender  : Policysender pod status and log checks
    9  | ai            : AI/model training, inference and ClickHouse usage
    10 | db_disk       : Database table sizes and disk usage (PostgreSQL, ClickHouse)
    11 | ui            : NWDAF UI web connection and service/pod status checks

Examples:
    # Run all checks (default)
    ./nwdaf-check-v2.sh

    # Run only node and kafka checks
    ./nwdaf-check-v2.sh 1 kafka

    # Use names instead of numbers
    ./nwdaf-check-v2.sh nodes ai

Notes:
    - You must be logged in with an account that appears as 'nwdaf-admin'
        (the script checks `oc whoami` on startup).
    - The script runs many `oc exec` calls and expects ClickHouse/minio/kafka
        clients to be available inside target pods.

USAGE
                                exit 0 ;;
                        --list)
                                echo "Available checks:"
                                echo " 1   nodes         - Node status"
                                echo " 2   node_load     - Node CPU/Memory usage"
                                echo " 3   events        - Namespace events (warnings/errors)"
                                echo " 4   pods          - Namespace pod status"
                                echo " 5   kafka         - Kafka & CDR checks"
                                echo " 6   prb           - PRB / Datagw ingestion checks"
                                echo " 7   cmsweb        - CMSWEB FTP server and base station data"
                                echo " 8   policysender  - Policysender pod status and logs"
                                echo " 9   ai            - AI model/train/inference checks"
                                echo " 10  db_disk       - DB table sizes and disk usage"
                                echo " 11  ui            - NWDAF UI web connection checks"
                                exit 0 ;;
            *)
                echo "Unknown check: $1" >&2
                exit 1 ;;
        esac
        shift
    done
fi

allow() {
    local key="$1"
    if [[ $SELECT_ALL -eq 1 ]]; then
        return 0
    fi
    for k in "${SELECTED_KEYS[@]:-}"; do
        if [[ "$k" == "$key" ]]; then
            return 0
        fi
    done
    return 1
}

# -------------------- Helpers --------------------
print_hdr() { echo ""; echo "======================================"; echo " $1"; echo "======================================"; }

# 결과 기록 함수
record_result() {
    local check_name="$1"
    local status="$2"      # OK, WARNING, CRITICAL
    local message="$3"
    CHECK_RESULTS+=("$check_name|$status|$message")
}

# 요약 출력 함수
print_summary() {
    if [[ ${#CHECK_RESULTS[@]} -eq 0 ]]; then
        return 0
    fi
    
    echo ""
    echo "======================================"
    echo " 점검 결과 요약"
    echo "======================================"
    echo "실행일시 (KST): $EXEC_TIME_KST"
    echo ""
    
    local ok_count=0 warn_count=0 crit_count=0
    declare -a warnings=()
    declare -a criticals=()
    
    printf "%-30s %-12s %s\n" "CHECK ITEM" "STATUS" "SUMMARY"
    printf "%s\n" "---------------------------------------------------------------"
    
    for result in "${CHECK_RESULTS[@]}"; do
        IFS='|' read -r name status message <<< "$result" || continue
        printf "%-30s %-12s %s\n" "$name" "[$status]" "$message" || continue
        case "$status" in
            OK) ((ok_count++)) || true ;;
            WARNING) 
                ((warn_count++)) || true
                warnings+=("  - $name: $message") ;;
            CRITICAL) 
                ((crit_count++)) || true
                criticals+=("  - $name: $message") ;;
        esac
    done
    
    echo ""
    echo "---------------------------------------------------------------"
    echo "전체: ${#CHECK_RESULTS[@]}개 | ✓ OK: $ok_count | ⚠ WARNING: $warn_count | ✗ CRITICAL: $crit_count"
    
    if [[ $warn_count -gt 0 ]]; then
        echo ""
        echo "[주의 필요] WARNING 항목:"
        for w in "${warnings[@]}"; do
            echo "$w"
        done
    fi
    
    if [[ $crit_count -gt 0 ]]; then
        echo ""
        echo "[긴급 조치 필요] CRITICAL 항목:"
        for c in "${criticals[@]}"; do
            echo "$c"
        done
    fi
    
    echo "======================================"
}

# -------------------- Checks --------------------
check_nodes() {
    print_hdr "K8S 노드 연결 상태"
    node_status=$(oc get nodes --no-headers 2>/dev/null | awk '{print $2}' | sort | uniq || true)
    not_ready_nodes=$(oc get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1}' || true)
    if [[ "$node_status" == "Ready" && -z "${not_ready_nodes}" ]]; then
        echo "=> 모든 NWDAF 노드의 STATUS가 READY입니다. [OK]"
        record_result "K8S Nodes" "OK" "모든 노드 Ready"
    else
        if [[ -z "${not_ready_nodes}" ]]; then
            echo "=> 일부 노드의 상태가 정상적으로 표시되지 않습니다. [INFO]"
            record_result "K8S Nodes" "WARNING" "일부 노드 상태 미표시"
        else
            echo "=> READY가 아닌 노드가 존재합니다: ${not_ready_nodes} [CRITICAL]"
            record_result "K8S Nodes" "CRITICAL" "NotReady 노드: ${not_ready_nodes}"
        fi
    fi
    echo ""
    oc get nodes 2>/dev/null | grep -E 'ma[1-3]\\.ocp|nwdaf-wk0[1-3]' || echo "  해당 패턴의 노드 없음"
}

check_node_load() {
    print_hdr "K8S 노드별 시스템 부하 상태"
    top_all=$(oc adm top nodes --no-headers 2>/dev/null || true)
    top_filtered=$(echo "$top_all" | grep -E 'ma[1-3]\\.ocp|nwdaf-wk0[1-3]' || true)
    if [[ -z "$(echo "$top_filtered" | tr -d '[:space:]')" ]]; then
        echo "=> 필터에 해당하는 노드의 리소스 사용량을 가져오지 못했습니다 또는 해당 노드 없음"
        record_result "Node CPU/Memory" "WARNING" "리소스 사용량 조회 실패"
    else
        cpu_over=$(echo "$top_filtered" | awk '$3+0 > 90 {print $1":"$3}')
        mem_over=$(echo "$top_filtered" | awk '$5+0 > 90 {print $1":"$5}')
        cpu_warn=$(echo "$top_filtered" | awk '$3+0 > 70 && $3+0 <= 90 {print $1":"$3}')
        mem_warn=$(echo "$top_filtered" | awk '$5+0 > 70 && $5+0 <= 90 {print $1":"$5}')
        if [[ -n "$cpu_over" || -n "$mem_over" ]]; then
            echo "=> CPU/Memory 부하가 90%를 초과한 노드가 있습니다. [CRITICAL]"
            local detail=""
            [[ -n "$cpu_over" ]] && detail="CPU: $cpu_over"
            [[ -n "$mem_over" ]] && detail="$detail MEM: $mem_over"
            record_result "Node CPU/Memory" "CRITICAL" "90% 초과 - $detail"
        elif [[ -n "$cpu_warn" || -n "$mem_warn" ]]; then
            echo "=> CPU/Memory 부하가 70% 초과~90% 이하인 노드가 있습니다. [WARNING]"
            local detail=""
            [[ -n "$cpu_warn" ]] && detail="CPU: $cpu_warn"
            [[ -n "$mem_warn" ]] && detail="$detail MEM: $mem_warn"
            record_result "Node CPU/Memory" "WARNING" "70-90% 사용 - $detail"
        else
            echo "=> 모든 노드의 CPU/Memory 부하가 70% 이하입니다. [OK]"
            record_result "Node CPU/Memory" "OK" "모든 노드 70% 이하"
        fi
        echo ""; echo "$top_filtered"
    fi
}

check_namespace_events() {
    print_hdr "네임스페이스별 K8S 이벤트 확인"
    TMP_REPORT=$(mktemp)
    overall_warnings=0
    for ns in nwdaf kubeflow istio-system strimzi-kafka infra-datastore infra-log cert-manager auth oauth2-proxy infra-monitor metallb-system gpu-operator nwdaf-local-path; do
        events=$(oc get event -n "$ns" --no-headers 2>&1 || true)
        # ignore Normal/transient
        events_filtered=$(echo "$events" | grep -v -E '^$' | grep -v -E '\bNormal\b' | grep -v -E '\btransient\b' || true)
        if echo "$events_filtered" | grep -q "No resources found" || [[ -z "$(echo "$events_filtered" | tr -d '[:space:]')" ]]; then
            printf "%-15s %-10s %s\n" "$ns" "[OK]" "이벤트 없음" >> "$TMP_REPORT"
            : > /tmp/event_${ns}_last24h.txt
            continue
        fi
        echo "$events_filtered" > /tmp/event_${ns}_last24h.txt
        overall_warnings=1
        warn_count=$(echo "$events_filtered" | sed '/^\s*$/d' | wc -l | tr -d ' ')
        if [[ $warn_count -gt 0 ]]; then
            printf "%-15s %-10s %s\n" "$ns" "[WARNING]" "${warn_count}건" >> "$TMP_REPORT"
        else
            printf "%-15s %-10s %s\n" "$ns" "[OK]" "이벤트 없음" >> "$TMP_REPORT"
        fi
    done
    if [[ $overall_warnings -eq 0 ]]; then
        echo "=> 전체 네임스페이스에서 K8S 이벤트 특이사항이 없습니다. [OK]"
        record_result "Namespace Events" "OK" "모든 네임스페이스 정상"
    else
        echo "=> 일부 네임스페이스에서 Warning 이벤트가 존재합니다. [WARNING]"
        local event_summary=$(cat "$TMP_REPORT" | grep WARNING | awk '{print $1":"$3}' | tr '\n' ' ' || true)
        record_result "Namespace Events" "WARNING" "경고 발견: $event_summary"
    fi
    printf "\n"; printf "%-15s %-10s %s\n" "NAMESPACE" "STATUS" "DETAILS"; printf "%s\n" "---------------------------------------------------------"
    cat "$TMP_REPORT"; rm -f "$TMP_REPORT"
}

check_namespace_pods() {
    print_hdr "네임스페이스별 파드 상태"
    TMP_POD_REPORT=$(mktemp)
    overall_pod_issues=0
    namespaces=(nwdaf kubeflow istio-system strimzi-kafka infra-datastore infra-log cert-manager auth oauth2-proxy infra-monitor metallb-system gpu-operator nwdaf-local-path)
    for ns in "${namespaces[@]}"; do
        pods_wide=$(oc get pod -n "$ns" -o wide --no-headers 2>/dev/null || true)
        pods_fmt=$(echo "$pods_wide" | awk 'NF>=5 {printf "%-36s %-6s %-10s %-8s %-4s\n", $1, $2, $3, $4, $5}')
        if [[ -z "$(echo "$pods_fmt" | tr -d '[:space:]')" ]]; then
            : > /tmp/pods_${ns}.txt
        else
            printf "%-36s %-6s %-10s %-8s %-4s\n" "NAME" "READY" "STATUS" "RESTARTS" "AGE" > /tmp/pods_${ns}.txt
            echo "$pods_fmt" >> /tmp/pods_${ns}.txt
        fi
        issues=$(echo "$pods_wide" | grep -E 'Error|Failed|Unknown|Pending|CrashLoopBackOff' || true)
        if [[ -n "$issues" ]]; then
            issue_count=$(echo "$issues" | sed '/^\s*$/d' | wc -l | tr -d ' ')
            printf "%-15s %-10s %s\n" "$ns" "[CRITICAL]" "${issue_count}건 이상 상태" >> "$TMP_POD_REPORT"
            overall_pod_issues=1
        else
            printf "%-15s %-10s %s\n" "$ns" "[OK]" "이상 상태 없음" >> "$TMP_POD_REPORT"
        fi
    done
    if [[ $overall_pod_issues -eq 0 ]]; then
        echo "=> 전체 네임스페이스에서 이상 상태의 파드가 없습니다. [OK]"
        record_result "Namespace Pods" "OK" "모든 파드 정상"
    else
        echo "=> 일부 네임스페이스에서 이상 상태의 파드가 있습니다. [CRITICAL]"
        local pod_summary=$(cat "$TMP_POD_REPORT" | grep CRITICAL | awk '{print $1":"$3}' | tr '\n' ' ' || true)
        record_result "Namespace Pods" "CRITICAL" "이상 파드: $pod_summary"
    fi
    printf "\n"; printf "%-15s %-10s %s\n" "NAMESPACE" "STATUS" "DETAILS"; printf "%s\n" "---------------------------------------------------------"
    cat "$TMP_POD_REPORT"; echo ""
    for ns in "${namespaces[@]}"; do
        pods_slim=$(cat /tmp/pods_${ns}.txt 2>/dev/null || true)
        if [[ -z "$(echo "$pods_slim" | tr -d '[:space:]')" ]]; then
            echo "## $ns: (파드 정보 없음)"
        else
            echo "## $ns 네임스페이스 파드 목록"
            echo "$pods_slim"; echo ""
        fi
    done
    rm -f "$TMP_POD_REPORT"
    for ns in "${namespaces[@]}"; do rm -f /tmp/pods_${ns}.txt; done
}

check_kafka() {
    print_hdr "IPMDN 연동 (CDR 데이터) 점검"
    NAMESPACE="strimzi-kafka"
    BOOTSTRAP_SERVER="kafka-kafka-bootstrap.${NAMESPACE}:9092"
    CONSUMER_GROUPS=("nwdaf-clickhouse" "policysender")
    INTERVAL=3
    BROKER_PODS=($(oc get pod -n $NAMESPACE -l strimzi.io/broker-role=true -o jsonpath='{.items[*].metadata.name}'))

    echo "[1] Kafka 컨트롤러 상태 확인"
    controller_pods=$(oc get pod -n $NAMESPACE -l strimzi.io/controller-role=true --no-headers 2>/dev/null || true)
    if [[ -z "$(echo "$controller_pods" | tr -d '[:space:]')" ]]; then
        echo "=> Kafka controller 파드를 찾을 수 없습니다. [CRITICAL]"
        record_result "Kafka Controller" "CRITICAL" "컨트롤러 파드 없음"
    else
        nonrun=$(echo "$controller_pods" | awk '$3 != "Running" {print $1}' || true)
        if [[ -z "$(echo "$nonrun" | tr -d '[:space:]')" ]]; then
            echo "=> Kafka 컨트롤러 파드가 모두 Running 상태입니다. [OK]"
            record_result "Kafka Controller" "OK" "모두 Running"
        else
            echo "=> Running이 아닌 컨트롤러 파드: $nonrun [CRITICAL]"
            record_result "Kafka Controller" "CRITICAL" "비정상: $nonrun"
        fi
    fi
    oc get pod -n $NAMESPACE -l strimzi.io/controller-role=true || true

    echo ""; echo "[2] Kafka 브로커 상태 확인"
    broker_pods=$(oc get pod -n $NAMESPACE -l strimzi.io/broker-role=true --no-headers 2>/dev/null || true)
    if [[ -z "$(echo "$broker_pods" | tr -d '[:space:]')" ]]; then
        echo "=> Kafka broker 파드를 찾을 수 없습니다. [CRITICAL]"
        record_result "Kafka Broker" "CRITICAL" "브로커 파드 없음"
    else
        nonrunning_brokers=$(echo "$broker_pods" | awk '$3 != "Running" {print $1}' || true)
        if [[ -z "$(echo "$nonrunning_brokers" | tr -d '[:space:]')" ]]; then
            echo "=> Kafka 브로커 파드가 모두 Running 상태입니다. [OK]"
            record_result "Kafka Broker" "OK" "모두 Running"
        else
            echo "=> Running이 아닌 브로커 파드: $nonrunning_brokers [CRITICAL]"
            record_result "Kafka Broker" "CRITICAL" "비정상: $nonrunning_brokers"
        fi
    fi
    oc get pod -n $NAMESPACE -l strimzi.io/broker-role=true || true

    echo ""; echo "[3] Kafka 기타 서비스 상태"
    for sel in "app.kubernetes.io/name=entity-operator" "app.kubernetes.io/name=kafka-exporter" "name=strimzi-cluster-operator"; do
        echo "NAME: $sel"
        oc get pod -n $NAMESPACE -l "$sel" --no-headers 2>/dev/null | awk '{printf "%-42s %-6s %-10s %-10s %-6s\n", $1, $2, $3, $4, $5}' || true
    done

    exec_on_working_broker() {
        local CMD="$1"
        for b in "${BROKER_PODS[@]:-}"; do
            if oc exec -n $NAMESPACE $b -- bash -c "$CMD" 2>&1 | awk '!/Defaulted container/ {print}'; then
                return 0
            fi
        done
        return 1
    }

    echo ""; echo "[4] Consumer Group Lag 확인"
    for group in "${CONSUMER_GROUPS[@]}"; do
        echo "Consumer Group: $group"
        TMP1=$(mktemp); TMP2=$(mktemp); TMP3=$(mktemp)
        exec_on_working_broker "/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server $BOOTSTRAP_SERVER --group $group --describe 2>/dev/null" | \
            grep -Ev 'Defaulted container|^>> 시도 중|^GROUP|^Consumer group' | \
            awk 'NF>=6{cid=$7;n=split(cid,a,/-|\.|_/);newcid="";prev="";for(i=1;i<=n;i++){tok=a[i];l=tolower(tok); if(l!=prev){ if(newcid=="") newcid=tok; else newcid=newcid"-"tok; prev=l}} if(newcid=="") newcid=cid; if(length(newcid)>30) newcid=substr(newcid,1,30)"..."; print $2"\t"$3"\t"$6"\t"newcid}' | sort > $TMP1 || true
        sleep $INTERVAL
        exec_on_working_broker "/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server $BOOTSTRAP_SERVER --group $group --describe 2>/dev/null" | \
            grep -Ev 'Defaulted container|^>> 시도 중|^GROUP|^Consumer group' | \
            awk 'NF>=6{cid=$7;n=split(cid,a,/-|\.|_/);newcid="";prev="";for(i=1;i<=n;i++){tok=a[i];l=tolower(tok); if(l!=prev){ if(newcid=="") newcid=tok; else newcid=newcid"-"tok; prev=l}} if(newcid=="") newcid=cid; if(length(newcid)>30) newcid=substr(newcid,1,30)"..."; print $2"\t"$3"\t"$6"\t"newcid}' | sort > $TMP2 || true
        sleep $INTERVAL
        exec_on_working_broker "/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server $BOOTSTRAP_SERVER --group $group --describe 2>/dev/null" | \
            grep -Ev 'Defaulted container|^>> 시도 중|^GROUP|^Consumer group' | \
            awk 'NF>=6{cid=$7;n=split(cid,a,/-|\.|_/);newcid="";prev="";for(i=1;i<=n;i++){tok=a[i];l=tolower(tok); if(l!=prev){ if(newcid=="") newcid=tok; else newcid=newcid"-"tok; prev=l}} if(newcid=="") newcid=cid; if(length(newcid)>30) newcid=substr(newcid,1,30)"..."; print $2"\t"$3"\t"$6"\t"newcid}' | sort > $TMP3 || true
        printf "%-20s %-20s %-10s %-12s %-12s %-12s %-33s\n" "GROUP" "TOPIC" "PARTITION" "LAG-1" "LAG-2" "LAG-3" "CONSUMER-ID"
        paste $TMP1 $TMP2 $TMP3 | awk -F"\t" -v g="$group" '{t1=$1;p1=$2;l1=$3;c1=$4; t2=$5;p2=$6;l2=$7;c2=$8; t3=$9;p3=$10;l3=$11;c3=$12; if(t1==t2&&t2==t3&&p1==p2&&p2==p3){cid=(c1!=""?c1:(c2!=""?c2:c3)); printf "%-20s %-20s %-10s %-12s %-12s %-12s %-33s\n", g, t1, p1, l1, l2, l3, cid}}' || true
        rm -f $TMP1 $TMP2 $TMP3 || true
        echo ""
    done

    echo "[5] CDR 데이터 DB 적재 상태 체크"
    CDR_DB=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c "clickhouse-client --password=\$CLICKHOUSE_ADMIN_PASSWORD -d nwdaf -q \"SELECT event_time, count(*) FROM stat_ipmdn_recv WHERE event_time > now() - toIntervalSecond(20) GROUP BY event_time ORDER BY event_time DESC LIMIT 5\"" 2>/dev/null || true)
    CDR_ROWS=$(echo "$CDR_DB" | sed '/^\s*$/d' | wc -l | tr -d ' ')
    if [[ -n "$(echo "$CDR_DB" | tr -d '[:space:]')" && "$CDR_ROWS" -ge 1 ]]; then
        echo "=> CDR 데이터가 정상적으로 적재되고 있습니다. [OK]"
        record_result "CDR Data Ingestion" "OK" "최근 20초 내 적재 확인"
        echo "$CDR_DB" | sed 's/^/  /'
    else
        echo "=> CDR 데이터가 정상적으로 적재되지 않고 있습니다. [CRITICAL]"
        record_result "CDR Data Ingestion" "CRITICAL" "최근 데이터 없음 (rows: ${CDR_ROWS:-0})"
        echo "  (rows: ${CDR_ROWS:-0})"
    fi
}

check_prb() {
    print_hdr "IDCUBE Datagw 연동 (PRB 데이터) 점검"
    echo "[1] datagw cronjob 상태 체크"
    datagw_jobs=$(oc get pod -n nwdaf | grep datagw | grep -E 'Error' || true)
    if [[ -z "$datagw_jobs" ]]; then
        echo "=> 상태값이 Error로 종료된 job이 없습니다. [OK]"
        record_result "PRB Datagw Jobs" "OK" "Error 상태 job 없음"
    else
        echo "=> Error로 종료된 job: $datagw_jobs [CRITICAL]"
        record_result "PRB Datagw Jobs" "CRITICAL" "Error job 발견: $datagw_jobs"
    fi
    echo ""; datagw_pods_full=$(oc get pod -n nwdaf | grep datagw 2>&1 || true)
    if [[ -z "$(echo "$datagw_pods_full" | tr -d '[:space:]')" ]]; then echo "    (datagw 파드 정보 없음)"; else echo "$datagw_pods_full" | sed 's/^/  /'; fi
    
    echo ""
    echo "[2] PRB 데이터 DB 적재 상태 체크"
    PRB_4G_RAW=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c "clickhouse-client --password=\$CLICKHOUSE_ADMIN_PASSWORD -d nwdaf -q \"SELECT event_date, count() FROM t_4g_cell_prb_5m WHERE event_date >= now() - INTERVAL 1 hour GROUP BY event_date ORDER BY event_date LIMIT 5\"" 2>/dev/null || true)
    PRB_5G_RAW=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c "clickhouse-client --password=\$CLICKHOUSE_ADMIN_PASSWORD -d nwdaf -q \"SELECT event_date, count() FROM t_5g_cell_prb_15m WHERE event_date >= now() - INTERVAL 1 hour GROUP BY event_date ORDER BY event_date LIMIT 5\"" 2>/dev/null || true)
    # event_date가 날짜+시간으로 분리되어 3개 필드로 출력됨: 날짜 시간 count
    PRB_4G_SUM=$(echo "$PRB_4G_RAW" | awk '{s+=($3+0)} END{print s+0}')
    PRB_5G_SUM=$(echo "$PRB_5G_RAW" | awk '{s+=($3+0)} END{print s+0}')
    if [[ ${PRB_4G_SUM:-0} -ge 1 && ${PRB_5G_SUM:-0} -ge 1 ]]; then 
        echo "=> PRB 데이터가 최근 1시간 내에 적재되고 있습니다. [OK]"
        record_result "PRB Data 4G/5G" "OK" "최근 1시간 내 적재 (4G:$PRB_4G_SUM, 5G:$PRB_5G_SUM)"
    else 
        echo "=> PRB 데이터 일부 또는 전체가 최근 1시간 내 적재되지 않았습니다. [CRITICAL]"
        record_result "PRB Data 4G/5G" "CRITICAL" "데이터 부족 (4G:$PRB_4G_SUM, 5G:$PRB_5G_SUM)"
    fi
    echo ""; echo "PRB_4G:"; if [[ -z "$(echo "$PRB_4G_RAW" | tr -d '[:space:]')" ]]; then echo "  없음"; else echo "$PRB_4G_RAW" | sed 's/^/  /'; fi
    echo ""; echo "PRB_5G:"; if [[ -z "$(echo "$PRB_5G_RAW" | tr -d '[:space:]')" ]]; then echo "  없음"; else echo "$PRB_5G_RAW" | sed 's/^/  /'; fi
}

check_cmsweb() {
    print_hdr "CMSWEB 연동 점검"
    echo "[1] cmsweb-ftp-server 파드 상태 체크"
    cmsweb_cmsweb_pods=$(oc get pod -n nwdaf | grep cmsweb | awk '$3 != "Running" {print $1}' || true)
    if [[ -z "$cmsweb_cmsweb_pods" ]]; then
        echo "=> cmsweb-ftp-server-primary(secondary) 파드가 Running 상태입니다. [OK]"
        record_result "CMSWEB FTP Server" "OK" "primary/secondary Running"
    else
        echo "=> Running 상태가 아닌 파드: $cmsweb_cmsweb_pods [CRITICAL]"
        record_result "CMSWEB FTP Server" "CRITICAL" "비정상: $cmsweb_cmsweb_pods"
    fi
    echo ""
    ftp_pods_output=$(oc get pod -n nwdaf -l app=ftp-server 2>&1 || true)
    if [[ -z "$(echo "$ftp_pods_output" | tr -d '[:space:]')" ]]; then
        echo "  (ftp-server 파드 정보 없음)"
    else
        echo "$ftp_pods_output" | sed 's/^/  /'
    fi

    echo ""
    echo "[2] cmsweb 기지국 데이터 DB 업데이트 체크"
    DB_UPD_RAW=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT max(update_time) FROM conn_pgsql_mv_t_cell_lte_all"' 2>/dev/null || true)
    DB_UPD_UTC=$(echo "$DB_UPD_RAW" | grep -v 'Defaulted container' | sed -n '/\S/,$p' | tail -n1 | tr -d '\r')
    
    # 판정 코멘트 먼저 출력
    if [[ -z "$DB_UPD_UTC" ]]; then
        echo "=> 최근 1시간 내 업데이트 없음 또는 정보 미존재 [CRITICAL]"
        record_result "CMSWEB Update" "CRITICAL" "업데이트 정보 없음"
    else
        # UTC 기준으로 시간 차이 계산
        DB_TIMESTAMP=$(TZ=UTC date --date="$DB_UPD_UTC" +%s 2>/dev/null || echo 0)
        NOW_TIMESTAMP=$(TZ=UTC date +%s)
        ONE_HOUR_AGO=$((NOW_TIMESTAMP - 3600))
        THREE_HOURS_AGO=$((NOW_TIMESTAMP - 10800))
        
        if [[ $DB_TIMESTAMP -ge $ONE_HOUR_AGO ]]; then
            echo "=> 최근 1시간 내 업데이트 완료 [OK]"
            record_result "CMSWEB Update" "OK" "최근 1시간 내 업데이트"
        elif [[ $DB_TIMESTAMP -ge $THREE_HOURS_AGO ]]; then
            echo "=> 최근 1~3시간 내 업데이트 [WARNING]"
            record_result "CMSWEB Update" "WARNING" "1~3시간 전 업데이트"
        else
            echo "=> 3시간 이상 미업데이트 [CRITICAL]"
            record_result "CMSWEB Update" "CRITICAL" "3시간 이상 미업데이트"
        fi
    fi
    
    # 실제 데이터 출력 (UTC 시간 그대로 표시)
    echo ""
    echo "최근 업데이트 시각: $DB_UPD_UTC"
}

check_policysender() {
    print_hdr "제어전송부 점검"
    echo "[1] 제어전송부 Pod 상태 점검"
    policysender_all_pods=$(oc get pod -n nwdaf -l app=policysender || true)
    running_count=$(oc get pod -n nwdaf --no-headers 2>/dev/null | awk '/policysender/ && $3 == "Running" {print $1}' | wc -l || true)
    if [[ "$running_count" -eq 2 ]]; then
        echo "=> 2개의 policysender 파드가 Running 상태입니다. [OK]"
        record_result "Policysender Pods" "OK" "2개 파드 Running"
    elif [[ "$running_count" -eq 1 ]]; then
        echo "=> 1개의 policysender 파드만 Running 상태입니다. [WARNING]"
        record_result "Policysender Pods" "WARNING" "1개 파드만 Running"
    else
        echo "=> Running 상태의 policysender 파드가 없습니다. [CRITICAL]"
        record_result "Policysender Pods" "CRITICAL" "Running 파드 없음"
    fi
    if [[ -z "$policysender_all_pods" ]]; then
        echo "  (policysender 파드 정보 없음)"
    else
        echo "$policysender_all_pods" | sed 's/^/  /'
    fi
    
    echo ""
    echo "[2] 제어전송부 Active Pod 확인"
    lease_holder=$(oc get lease -n nwdaf --no-headers 2>/dev/null | awk '$1=="policysender" {print $2}' || true)
    if [[ -n "$lease_holder" ]]; then
        echo "=> Active policysender 파드 (lease holder):"
        echo "  $lease_holder"
        policysender_pods="$lease_holder"
    else
        echo "=> Active policysender 파드가 없습니다. [CRITICAL]"
        policysender_pods=""
    fi
    
    echo ""
    echo "[3] 제어전송부 실시간 로그 점검"
    policysender_all_names=$(oc get pod -n nwdaf --no-headers 2>/dev/null | awk '/policysender/ {print $1}' || true)
    noninfo_found=0
    if [[ -n "$policysender_all_names" ]]; then
        for pod in $policysender_all_names; do
            logs_preview=$(oc logs -n nwdaf "$pod" --tail 20 2>/dev/null || true)
            if echo "$logs_preview" | grep -v 'INFO' | sed '/^\s*$/d' | grep -q '.'; then
                noninfo_found=1; break
            fi
        done
    fi
    if [[ "$noninfo_found" -eq 1 ]]; then
        echo "=> 실시간 로그에 INFO 이외의 로그가 존재합니다. [WARNING]"
    else
        echo "=> 실시간 로그에 특이사항이 없습니다. [OK]"
    fi
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
        warn_log=$(oc logs -n nwdaf "$pod" | grep -i 'error\|warn' | head -5 || true)
        if [[ -n "$warn_log" ]]; then
            echo "## $pod warn 로그 발견 (최대 5)"
            echo "$warn_log"
            warn_log_all=1
        fi
    done
    if [[ "$warn_log_all" -eq 0 ]]; then
        echo "=> 모든 policysender 파드에 Error/Warn 로그가 없습니다. [OK]"
        record_result "Policysender Logs" "OK" "Warn/Error 로그 없음"
    else
        echo "=> Error/Warn 로그가 존재하는 policysender 파드가 있습니다. [WARNING]"
        record_result "Policysender Logs" "WARNING" "Warn/Error 로그 발견"
    fi
}

check_ai() {
    print_hdr "학습/추론 점검"
    echo "[1] 파이프라인 Pod 상태 체크"
    runof_jobs=$(oc get pod -n nwdaf | grep runof | grep -E 'Error' || true)
    if [[ -z "$runof_jobs" ]]; then 
        echo "=> 상태값이 Error로 종료된 job이 없습니다. [OK]"
        record_result "AI Training Jobs" "OK" "Error 상태 job 없음"
    else 
        echo "=> Error로 종료된 job: $runof_jobs [CRITICAL]"
        record_result "AI Training Jobs" "CRITICAL" "Error job: $runof_jobs"
    fi

    echo ""
    echo "[2] 추론 결과 데이터 적재 상태 체크"
    PRED_PRB=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT window_end, model_type, count() FROM ai.t_cell_prb_usage_predicted WHERE model_type = '\''prb'\'' GROUP BY window_end, model_type ORDER BY window_end DESC LIMIT 10"' 2>/dev/null || true)
    PRED_PRB_ROWS=$(echo "$PRED_PRB" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    # window_end가 날짜+시간으로 분리되어 4개 필드로 출력됨: 날짜 시간 model_type count
    PRED_PRB_SUM=$(echo "$PRED_PRB" | awk 'NF>=4 {s+=($4+0)} END{print s+0}')
    if [[ -n "$(echo "$PRED_PRB" | tr -d '[:space:]')" && "$PRED_PRB_ROWS" -ge 1 && "$PRED_PRB_SUM" -ge 1 ]]; then 
        echo "=> [prb] 추론 결과가 정상적으로 적재되고 있습니다. [OK]"
        record_result "AI PRB Prediction" "OK" "추론 결과 정상 적재"
    else 
        echo "=> [prb] 추론 결과가 정상적으로 적재되지 않았습니다. [CRITICAL]"
        record_result "AI PRB Prediction" "CRITICAL" "추론 결과 없음"
    fi
    if [[ -n "$(echo "$PRED_PRB" | tr -d '[:space:]')" ]]; then echo "$PRED_PRB" | sed 's/^/  /'; fi

    PRED_LG=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT window_end, model_type, count() FROM ai.t_cell_prb_usage_predicted WHERE model_type IN ('\''lstm'\'','\''gru'\'') GROUP BY window_end, model_type ORDER BY window_end DESC LIMIT 30"' 2>/dev/null || true)
    # window_end가 날짜+시간으로 분리되어 4개 필드로 출력됨: 날짜 시간 model_type count
    PRED_LG_SUM=$(echo "$PRED_LG" | awk 'NF>=4 {s+=($4+0)} END{print s+0}')
    PRED_LG_ISSUES=$(echo "$PRED_LG" | awk 'NF>=4 {w=$1" "$2; t=$3; c=$4+0; if(t=="lstm") lstm[w]+=c; else if(t=="gru") gru[w]+=c} END{for(w in lstm){ if((lstm[w]+0)>0 && (gru[w]+0)>0) print w" BOTH_LSTM_GRU"}}')
    PRED_LG_ISSUES_CNT=$(echo "$PRED_LG_ISSUES" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    if [[ "$PRED_LG_SUM" -ge 1 && "$PRED_LG_ISSUES_CNT" -eq 0 ]]; then 
        echo "=> [lstm/gru] lstm 또는 gru 중 하나 이상의 결과가 적재되어 있습니다. [OK]"
        record_result "AI LSTM/GRU Models" "OK" "모델 결과 적재 확인"
    elif [[ "$PRED_LG_SUM" -ge 1 && "$PRED_LG_ISSUES_CNT" -gt 0 ]]; then 
        echo "=> [lstm/gru] lstm/gru 적재에서 충돌(동시 존재)이 발견되었습니다. [WARNING]"
        record_result "AI LSTM/GRU Models" "WARNING" "모델 충돌 발견"
    else 
        echo "=> [lstm/gru] lstm 또는 gru 데이터가 존재하지 않습니다. [CRITICAL]"
        record_result "AI LSTM/GRU Models" "CRITICAL" "모델 데이터 없음"
    fi
    if [[ -n "$(echo "$PRED_LG" | tr -d '[:space:]')" ]]; then echo "$PRED_LG" | sed 's/^/  /'; fi

    echo ""
    echo "[3] 추론용 데이터셋 적재 상태 체크"
    INFER_DATA=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT window_end, count() FROM ai.cell_usage_1m_latest WHERE window_end >= now() - toIntervalMinute(2) GROUP BY 1 ORDER BY 1 DESC"' 2>/dev/null || true)
    INFER_ROWS=$(echo "$INFER_DATA" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    if [[ -n "$(echo "$INFER_DATA" | tr -d '[:space:]')" && "$INFER_ROWS" -ge 1 ]]; then 
        echo "=> 추론용 데이터셋이 정상적으로 적재되고 있습니다. [OK]"
        record_result "AI Inference Dataset" "OK" "최근 2분 내 데이터 확인"
        echo "$INFER_DATA" | sed 's/^/  /'
    else 
        echo "=> 추론용 데이터셋이 정상적으로 적재되지 않았습니다. [CRITICAL]"
        record_result "AI Inference Dataset" "CRITICAL" "최근 2분 내 데이터 없음"
    fi

    echo ""
    echo "[4] 학습용 데이터셋 적재 상태 체크"
    TRAIN_DATA=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT window_end, count() FROM ai.cell_usage_hist_5m WHERE window_end >= now() - toIntervalMinute(70) GROUP BY 1 ORDER BY 1 DESC LIMIT 5"' 2>/dev/null || true)
    TRAIN_ROWS=$(echo "$TRAIN_DATA" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    if [[ -n "$(echo "$TRAIN_DATA" | tr -d '[:space:]')" && "$TRAIN_ROWS" -ge 1 ]]; then 
        echo "=> 학습용 데이터셋이 정상적으로 적재되고 있습니다. [OK]"
        record_result "AI Training Dataset" "OK" "학습 데이터 적재 확인"
    else 
        echo "=> 학습용 데이터셋이 정상적으로 적재되지 않았습니다. [CRITICAL]"
        record_result "AI Training Dataset" "CRITICAL" "학습 데이터 없음"
    fi

    echo ""
    echo "[5] 학습 히스토리 조회"
    model_seq_result=$(oc exec -n nwdaf clickhouse-shard0-0 -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT model_type, excution_end, model_seq, cell_count, train_result FROM ai.model_train_hist ORDER BY model_seq DESC LIMIT 20"' 2>/dev/null || true)
    echo "$model_seq_result" | grep Success || true

    echo ""
    echo "[6] 모델 히스토리 및 파일 점검"
    minio_hist=$(oc exec -n kubeflow minio-nwdaf-0 -- sh -c "mc ls local/model-repo-history" 2>/dev/null || true)
    if [[ -z "$(echo "$minio_hist" | tr -d '[:space:]')" ]]; then 
        echo "=> 모델 히스토리 파일 미존재 [CRITICAL]"
        record_result "MinIO Model History" "CRITICAL" "히스토리 파일 없음"
    else 
        echo "=> 모델 히스토리 파일 존재 확인 [OK]"
        record_result "MinIO Model History" "OK" "히스토리 파일 존재"
    fi

    lstm_files=$(oc exec -n kubeflow minio-nwdaf-0 -c minio -- sh -c "mc ls --recursive local/model-repo/lstm_model" 2>/dev/null || true)
    gru_files=$(oc exec -n kubeflow minio-nwdaf-0 -c minio -- sh -c "mc ls --recursive local/model-repo/gru_model" 2>/dev/null || true)
    
    local model_status=""
    if [[ -z "$(echo "$lstm_files" | tr -d '[:space:]')" && -z "$(echo "$gru_files" | tr -d '[:space:]')" ]]; then
        echo "=> LSTM/GRU 모델 파일 미존재 [CRITICAL]"
        record_result "MinIO Model Files" "CRITICAL" "LSTM/GRU 파일 없음"
    elif [[ -n "$(echo "$lstm_files" | tr -d '[:space:]')" && -n "$(echo "$gru_files" | tr -d '[:space:]')" ]]; then
        echo "=> LSTM/GRU 모델 파일 모두 존재 확인 [OK]"
        record_result "MinIO Model Files" "OK" "LSTM/GRU 파일 존재"
    else
        if [[ -z "$(echo "$lstm_files" | tr -d '[:space:]')" ]]; then
            echo "=> LSTM 모델 파일 미존재 [CRITICAL]"
            model_status="LSTM 파일 없음"
        else
            echo "=> LSTM 모델 파일 존재 확인 [OK]"
        fi
        if [[ -z "$(echo "$gru_files" | tr -d '[:space:]')" ]]; then
            echo "=> GRU 모델 파일 미존재 [CRITICAL]"
            model_status="$model_status GRU 파일 없음"
        else
            echo "=> GRU 모델 파일 존재 확인 [OK]"
        fi
        record_result "MinIO Model Files" "WARNING" "일부 파일 누락: $model_status"
    fi
}

check_db_disk() {
    print_hdr "DB/Disk 사용량 점검"
    
    echo "[1] PostgreSQL 데이터베이스 용량"
    # PostgreSQL DB 크기 확인
    POSTGRES_NS=nwdaf
    POSTGRES_POD=$(oc get pod -n $POSTGRES_NS --no-headers | grep cloudnative-pg-cluster | awk 'NR==1{print $1}' || true)
    if [[ -n "$POSTGRES_POD" ]]; then
        # 바이트 단위로 크기 확인 (1GB = 1073741824 bytes)
        postgres_max_bytes=$(oc exec -n $POSTGRES_NS $POSTGRES_POD -- psql -U postgres -t -c "SELECT MAX(pg_database_size(datname)) FROM pg_database;" 2>/dev/null | tr -d ' ' || echo "0")
        postgres_space=$(oc exec -n $POSTGRES_NS $POSTGRES_POD -- psql -U postgres -c "SELECT datname AS db_name, pg_size_pretty(pg_database_size(datname)) AS used FROM pg_database ORDER BY pg_database_size(datname) DESC;" 2>/dev/null || true)
        
        # 판정 코멘트 먼저 출력 (1GB = 1073741824 bytes)
        if [[ ${postgres_max_bytes:-0} -gt 1073741824 ]]; then
            local max_db_size=$(oc exec -n $POSTGRES_NS $POSTGRES_POD -- psql -U postgres -t -c "SELECT pg_size_pretty(${postgres_max_bytes});" 2>/dev/null | tr -d ' ' || echo "${postgres_max_bytes} bytes")
            echo "=> PostgreSQL DB 사용량 1GB 초과 [WARNING]"
            record_result "PostgreSQL DB Size" "WARNING" "최대 DB ${max_db_size} 사용 중"
        else
            echo "=> PostgreSQL DB 용량 정상 [OK]"
            record_result "PostgreSQL DB Size" "OK" "모든 DB 1GB 이하"
        fi
        # 실제 데이터 출력 (헤더 명시적 추가)
        echo ""
        printf "%-30s %15s\n" "DATABASE" "SIZE"
        printf "%s\n" "-----------------------------------------------"
        # psql 출력에서 헤더(2줄)와 footer(1줄) 제거 후 데이터만 출력
        echo "$postgres_space" | tail -n +3 | head -n -1 | awk '{printf "%-30s %15s\n", $1, $3" "$4}' || true
    else
        echo "[PostgreSQL 파드를 찾을 수 없습니다.] [CRITICAL]"
        record_result "PostgreSQL DB Size" "CRITICAL" "파드 없음"
    fi

    echo ""
    echo "[2] ClickHouse 테이블스페이스 및 디스크"
    # ClickHouse 테이블스페이스 및 디스크 여유공간
    CLICKHOUSE_NS=nwdaf; CLICKHOUSE_POD=clickhouse-shard0-0
    if oc get pod -n $CLICKHOUSE_NS $CLICKHOUSE_POD &>/dev/null; then
        echo ""
        echo "## ClickHouse 테이블스페이스 사용량"
        clickhouse_space=$(oc exec -n $CLICKHOUSE_NS $CLICKHOUSE_POD -- bash -c "clickhouse-client --password=\$CLICKHOUSE_ADMIN_PASSWORD --query \"SELECT database, formatReadableSize(sum(bytes)) AS used, any(disk_name) AS disk FROM system.parts WHERE active GROUP BY database ORDER BY sum(bytes) DESC;\"" 2>/dev/null || true)
        
        # 판정 코멘트 먼저 출력 (1TiB = 1024 GiB) - TiB, GiB, MiB 모두 처리 (ClickHouse는 헤더 없음)
        max_gib=$(echo "$clickhouse_space" | awk '
            NF >= 3 {
                val = $2 + 0
                unit = $3
                if (unit == "TiB") gib = val * 1024
                else if (unit == "GiB") gib = val
                else if (unit == "MiB") gib = val / 1024
                else gib = 0
                if (gib > max) max = gib
            }
            END {print max + 0}
        ')
        if awk -v max="$max_gib" 'BEGIN {exit (max > 1024) ? 0 : 1}'; then
            echo "=> ClickHouse 사용량 1TiB 초과 [WARNING]"
            record_result "ClickHouse Table Size" "WARNING" "최대 ${max_gib}GiB 사용 중"
        else
            echo "=> 테이블스페이스 사용량 정상 [OK]"
            record_result "ClickHouse Table Size" "OK" "최대 ${max_gib}GiB 사용 중"
        fi
        # 실제 데이터 출력 (헤더 강조)
        echo ""
        printf "%-20s %15s  %s\n" "DATABASE" "USED" "DISK"
        printf "%s\n" "-------------------------------------------------------"
        # ClickHouse는 기본적으로 헤더를 출력하지 않으므로 전체 출력
        echo "$clickhouse_space" | grep -v '^$' | awk '{printf "%-20s %15s  %s\n", $1, $2" "$3, $4}' || true

        echo ""
        echo "## ClickHouse 디스크 여유 공간"
        clickhouse_disk=$(oc exec -n $CLICKHOUSE_NS $CLICKHOUSE_POD -- bash -c "clickhouse-client --password=\$CLICKHOUSE_ADMIN_PASSWORD --query \"SELECT name AS disk_name, path, formatReadableSize(free_space) AS free_space, formatReadableSize(total_space) AS total_space FROM system.disks;\"" 2>/dev/null || true)
        
        # 판정 코멘트 먼저 출력 - TiB, GiB, MiB 모두 처리 (ClickHouse는 헤더 없음)
        free_space_gib=$(echo "$clickhouse_disk" | awk '
            NF >= 4 {
                val = $3 + 0
                unit = $4
                if (unit == "TiB") gib = val * 1024
                else if (unit == "GiB") gib = val
                else if (unit == "MiB") gib = val / 1024
                else gib = 0
                if (gib < min || min == 0) { min = gib; min_str = $3 " " $4 }
            }
            END {print min + 0 "|" min_str}
        ')
        free_gib=$(echo "$free_space_gib" | cut -d'|' -f1)
        free_display=$(echo "$free_space_gib" | cut -d'|' -f2)
        
        if awk -v free="$free_gib" 'BEGIN {exit (free > 0 && free < 50) ? 0 : 1}'; then
            echo "=> ClickHouse 디스크 여유 공간 50GiB 미만 [WARNING]"
            record_result "ClickHouse Disk Space" "WARNING" "여유 공간 ${free_display} (${free_gib}GiB)"
        else
            echo "=> ClickHouse 디스크 여유 공간 충분 [OK]"
            record_result "ClickHouse Disk Space" "OK" "여유 공간 ${free_display:-충분} (${free_gib}GiB)"
        fi
        
        # 실제 데이터 출력 (헤더 강조)
        echo ""
        printf "%-15s %-35s %15s %15s\n" "DISK_NAME" "PATH" "FREE_SPACE" "TOTAL_SPACE"
        printf "%s\n" "--------------------------------------------------------------------------------"
        # ClickHouse는 기본적으로 헤더를 출력하지 않으므로 전체 출력
        echo "$clickhouse_disk" | grep -v '^$' | awk '{printf "%-15s %-35s %15s %15s\n", $1, $2, $3" "$4, $5" "$6}' || true
    else
        echo "[ClickHouse 파드를 찾을 수 없습니다.] [CRITICAL]"
        record_result "ClickHouse Disk Space" "CRITICAL" "파드 없음"
    fi
}

check_ui_connection() {
    print_hdr "NWDAF UI CONNECTION CHECK"
    
    echo "[1] 파드 상태 확인"
    UI_NS=nwdaf
    # api-gateway, frontend, backend 파드 조회
    pods_status=$(oc get pod -n $UI_NS --no-headers 2>/dev/null | grep -E "api-gateway|frontend|backend" || true)
    
    if [[ -z "$pods_status" ]]; then
        echo "=> UI 관련 파드를 찾을 수 없습니다. [CRITICAL]"
        record_result "UI Pods Status" "CRITICAL" "파드 없음"
    else
        # 각 파드의 Running 상태 확인
        not_running=$(echo "$pods_status" | awk '$3 != "Running" {print $1, $3}' || true)
        
        if [[ -z "$not_running" ]]; then
            echo "=> 모든 UI 파드가 Running 상태입니다. [OK]"
            record_result "UI Pods Status" "OK" "모든 파드 Running"
        else
            echo "=> 일부 파드가 Running 상태가 아닙니다. [WARNING]"
            record_result "UI Pods Status" "WARNING" "비정상 파드 존재"
        fi
        
        echo ""
        printf "%-45s %-12s %s\n" "NAME" "STATUS" "RESTARTS"
        printf "%s\n" "----------------------------------------------------------------------"
        echo "$pods_status" | awk '{printf "%-45s %-12s %s\n", $1, $3, $4}'
    fi
    
    echo ""
    echo "[2] 서비스 상태 확인"
    # api-gateway 서비스 조회 (api-gateway-150 제외)
    svc_status=$(oc get svc -n $UI_NS --no-headers 2>/dev/null | grep -w api-gateway || true)
    
    if [[ -z "$svc_status" ]]; then
        echo "=> api-gateway 서비스를 찾을 수 없습니다. [CRITICAL]"
        record_result "UI Service Status" "CRITICAL" "서비스 없음"
    else
        # LoadBalancer 타입 및 EXTERNAL-IP 확인
        svc_type=$(echo "$svc_status" | awk '{print $2}')
        external_ip=$(echo "$svc_status" | awk '{print $4}')
        
        if [[ "$svc_type" == "LoadBalancer" ]] && [[ -n "$external_ip" ]] && [[ "$external_ip" != "<pending>" ]] && [[ "$external_ip" != "<none>" ]]; then
            echo "=> api-gateway 서비스가 정상적으로 구성되었습니다. [OK]"
            record_result "UI Service Status" "OK" "LoadBalancer with EXTERNAL-IP: $external_ip"
        else
            if [[ "$svc_type" != "LoadBalancer" ]]; then
                echo "=> api-gateway 서비스가 LoadBalancer 타입이 아닙니다. [WARNING]"
                record_result "UI Service Status" "WARNING" "타입: $svc_type"
            elif [[ -z "$external_ip" ]] || [[ "$external_ip" == "<pending>" ]] || [[ "$external_ip" == "<none>" ]]; then
                echo "=> api-gateway 서비스에 EXTERNAL-IP가 할당되지 않았습니다. [WARNING]"
                record_result "UI Service Status" "WARNING" "EXTERNAL-IP 미할당"
            fi
        fi
        
        echo ""
        printf "%-30s %-15s %-20s %-20s %s\n" "NAME" "TYPE" "CLUSTER-IP" "EXTERNAL-IP" "PORT(S)"
        printf "%s\n" "---------------------------------------------------------------------------------------------"
        echo "$svc_status" | awk '{printf "%-30s %-15s %-20s %-20s %s\n", $1, $2, $3, $4, $5}'
    fi
    
    echo ""
    echo "[3] HTTPS 웹 접속 확인"
    # EXTERNAL-IP가 있으면 웹 접속 테스트
    if [[ -n "${external_ip:-}" ]] && [[ "$external_ip" != "<pending>" ]] && [[ "$external_ip" != "<none>" ]]; then
        # 서비스에서 포트 추출 (예: 30990:30990/TCP)
        port=$(echo "$svc_status" | awk '{print $5}' | grep -oP '^\d+' || echo "30990")
        test_url="https://${external_ip}:${port}"
        
        echo "접속 테스트 URL: $test_url"
        
        # 재시도 로직 포함 (최대 2회 시도)
        http_code="000"
        curl_err_file=$(mktemp)
        for attempt in 1 2; do
            http_code_raw=$(curl -kL -o /dev/null -w "%{http_code}" "$test_url" \
                --connect-timeout 15 --max-time 30 \
                --retry 1 --retry-delay 2 \
                2>"$curl_err_file" || echo "000")
            
            # 응답 코드에서 숫자만 추출 (첫 3자리)
            http_code=$(echo "$http_code_raw" | grep -oE '^[0-9]{3}' | head -1 || echo "000")
            
            if [[ "$http_code" != "000" ]]; then
                break
            fi
            
            if [[ $attempt -eq 1 ]]; then
                echo "   (1차 시도 실패, 재시도 중...)"
                sleep 2
            fi
        done
        
        # 실패 시 에러 메시지 출력
        if [[ "$http_code" == "000" ]] && [[ -s "$curl_err_file" ]]; then
            curl_error=$(head -n 1 "$curl_err_file" | cut -c 1-80)
            echo "   curl 에러: $curl_error"
        fi
        rm -f "$curl_err_file"
        
        # 2xx(성공) 또는 3xx(리다이렉션)은 정상으로 판단
        if [[ "$http_code" =~ ^[23] ]]; then
            echo "=> HTTPS 웹 접속 성공 (최종 응답 코드: $http_code) [OK]"
            record_result "UI Web Access" "OK" "HTTP $http_code"
        elif [[ "$http_code" == "000" ]]; then
            echo "=> HTTPS 웹 접속 실패 (타임아웃 또는 연결 불가) [CRITICAL]"
            record_result "UI Web Access" "CRITICAL" "연결 실패"
        else
            echo "=> HTTPS 웹 접속 실패 또는 비정상 응답 (응답 코드: $http_code) [WARNING]"
            record_result "UI Web Access" "WARNING" "HTTP $http_code"
        fi
    else
        echo "=> EXTERNAL-IP가 없어 웹 접속 테스트를 건너뜁니다. [SKIP]"
        record_result "UI Web Access" "WARNING" "EXTERNAL-IP 없음"
    fi
}

# -------------------- Runner --------------------
# Default MAIN_CHECKS order (can be overridden by setting ALLOWED_CHECKS)
# Mapping: 1=nodes,2=node_load,3=events,4=pods,5=kafka,6=prb,7=cmsweb,8=policysender,9=ai,10=db_disk

# 체크 실행 중 에러가 발생해도 계속 진행
set +e
set +u
set +o pipefail

if allow "1"; then check_nodes; fi
if allow "2"; then check_node_load; fi
if allow "3"; then check_namespace_events; fi
if allow "4"; then check_namespace_pods; fi
if allow "5"; then check_kafka; fi
if allow "6"; then check_prb; fi
if allow "7"; then check_cmsweb; fi
if allow "8"; then check_policysender; fi
if allow "9"; then check_ai; fi
if allow "10"; then check_db_disk; fi
if allow "11"; then check_ui_connection; fi

# 점검 결과 요약 출력
print_summary

# 임시 파일 정리
for ns in nwdaf kubeflow istio-system strimzi-kafka infra-datastore infra-log cert-manager auth oauth2-proxy infra-monitor metallb-system gpu-operator nwdaf-local-path; do
    rm -f /tmp/event_${ns}_last24h.txt
done

exit 0
