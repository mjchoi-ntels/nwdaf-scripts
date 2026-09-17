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

# 점검 대상 네임스페이스 목록 (단일 소스 - events/pods 두 함수에서 공유)
NAMESPACES=(nwdaf kubeflow istio-system strimzi-kafka infra-datastore infra-log cert-manager auth oauth2-proxy infra-monitor metallb-system gpu-operator nwdaf-local-path)

# ClickHouse 파드 자동 감지 (clickhouse-shard0-0 또는 clickhouse-local-shard0-0)
CH_POD=$(oc get pod -n nwdaf --no-headers 2>/dev/null | awk '/^clickhouse(-local)?-shard0-0/{print $1; exit}' || true)

# 임시 파일 작업 디렉토리 (EXIT 트랩으로 정상/비정상 종료 시 모두 자동 정리)
SCRIPT_TMPDIR=$(mktemp -d)
trap 'rm -rf "$SCRIPT_TMPDIR"' EXIT

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
Usage: itm-check-v101p3.sh [checks...]

Description:
    Run ITM operational checks against the OpenShift cluster. Without arguments
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
    11 | ui            : ITM UI web connection and service/pod status checks

Examples:
    # Run all checks (default)
    ./itm-check-v101p3.sh

    # Run only node and kafka checks
    ./itm-check-v101p3.sh 1 kafka

    # Use names instead of numbers
    ./itm-check-v101p3.sh nodes ai

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
                                echo " 11  ui            - ITM UI web connection checks"
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

# 인라인 출력 + 요약 기록을 한번에 처리하는 헬퍼
# 사용법: report "점검명" "STATUS" "메시지"
report() {
    local check_name="$1"
    local status="$2"
    local message="$3"
    echo "=> $message [$status]"
    record_result "$check_name" "$status" "$message"
}

# Kafka 브로커 파드 중 정상 동작하는 것에 명령 실행
# 사용 변수: NAMESPACE, BROKER_PODS (check_kafka에서 설정)
exec_on_working_broker() {
    local CMD="$1"
    for b in "${BROKER_PODS[@]:-}"; do
        if oc exec -n $NAMESPACE $b -- bash -c "$CMD" 2>&1 | awk '!/Defaulted container/ {print}'; then
            return 0
        fi
    done
    return 1
}

# Consumer Group Lag 스냅샷을 파일에 기록
# 사용법: get_lag_snapshot <group> <outfile>
# 사용 변수: BOOTSTRAP_SERVER (check_kafka에서 설정)
get_lag_snapshot() {
    local group="$1"
    local outfile="$2"
    exec_on_working_broker "/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server $BOOTSTRAP_SERVER --group $group --describe 2>/dev/null" | \
        grep -Ev 'Defaulted container|^>> 시도 중|^GROUP|^Consumer group' | \
        awk 'NF>=6{cid=$7;n=split(cid,a,/-|\.|_/);newcid="";prev="";for(i=1;i<=n;i++){tok=a[i];l=tolower(tok); if(l!=prev){ if(newcid=="") newcid=tok; else newcid=newcid"-"tok; prev=l}} if(newcid=="") newcid=cid; if(length(newcid)>30) newcid=substr(newcid,1,30)"..."; print $2"\t"$3"\t"$6"\t"newcid}' | sort > "$outfile" || true
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
    
    local ok_count=0 warn_count=0 crit_count=0 info_count=0
    declare -a warnings=()
    declare -a criticals=()
    declare -a infos=()
    
    printf "%-30s %-12s %s\n" "CHECK ITEM" "STATUS" "SUMMARY"
    printf "%s\n" "---------------------------------------------------------------"
    
    for result in "${CHECK_RESULTS[@]}"; do
        IFS='|' read -r name status message <<< "$result" || continue
        printf "%-30s %-12s %s\n" "$name" "[$status]" "$message" || continue
        case "$status" in
            OK) ((ok_count++)) || true ;;
            INFO)
                ((info_count++)) || true
                infos+=("  - $name: $message") ;;
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
    echo "전체: ${#CHECK_RESULTS[@]}개 | ✓ OK: $ok_count | ℹ INFO: $info_count | ⚠ WARNING: $warn_count | ✗ CRITICAL: $crit_count"

    if [[ $info_count -gt 0 ]]; then
        echo ""
        echo "[참고] INFO 항목:"
        for i in "${infos[@]}"; do
            echo "$i"
        done
    fi

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
    # control-plane 또는 nwdaf Role을 포함하는 노드만 점검 대상
    target_nodes=$(oc get nodes --no-headers 2>/dev/null | awk '$3 ~ /control-plane|nwdaf/' || true)

    if [[ -z "${target_nodes//[[:space:]]/}" ]]; then
        report "K8S Nodes" "WARNING" "대상 노드 없음 (control-plane/nwdaf Role)"
    else
        node_status=$(echo "$target_nodes" | awk '{print $2}' | sort -u || true)
        not_ready_nodes=$(echo "$target_nodes" | awk '$2 != "Ready" {print $1}' || true)
        if [[ "$node_status" == "Ready" && -z "${not_ready_nodes}" ]]; then
            report "K8S Nodes" "OK" "모든 대상 노드 Ready"
        elif [[ -z "${not_ready_nodes}" ]]; then
            report "K8S Nodes" "WARNING" "일부 노드 상태 미표시"
        else
            report "K8S Nodes" "CRITICAL" "NotReady 노드: ${not_ready_nodes}"
        fi
    fi
    echo ""
    printf "  %-40s %-10s %s\n" "NAME" "STATUS" "ROLES"
    echo "$target_nodes" | awk 'NF {printf "  %-40s %-10s %s\n", $1, $2, $3}'
}

check_node_load() {
    print_hdr "K8S 노드별 시스템 부하 상태"
    top_all=$(oc adm top nodes --no-headers 2>/dev/null || true)
    top_filtered=$(echo "$top_all" | grep -E 'ma[1-3]\\.ocp|nwdaf-wk0[1-3]' || true)
    if [[ -z "${top_filtered//[[:space:]]/}" ]]; then
        report "Node CPU/Memory" "WARNING" "리소스 사용량 조회 실패"
    else
        cpu_over=$(echo "$top_filtered" | awk '$3+0 > 90 {print $1":"$3}')
        mem_over=$(echo "$top_filtered" | awk '$5+0 > 90 {print $1":"$5}')
        cpu_warn=$(echo "$top_filtered" | awk '$3+0 > 70 && $3+0 <= 90 {print $1":"$3}')
        mem_warn=$(echo "$top_filtered" | awk '$5+0 > 70 && $5+0 <= 90 {print $1":"$5}')
        if [[ -n "$cpu_over" || -n "$mem_over" ]]; then
            local detail=""
            [[ -n "$cpu_over" ]] && detail="CPU: $cpu_over"
            [[ -n "$mem_over" ]] && detail="$detail MEM: $mem_over"
            report "Node CPU/Memory" "CRITICAL" "90% 초과 - $detail"
        elif [[ -n "$cpu_warn" || -n "$mem_warn" ]]; then
            local detail=""
            [[ -n "$cpu_warn" ]] && detail="CPU: $cpu_warn"
            [[ -n "$mem_warn" ]] && detail="$detail MEM: $mem_warn"
            report "Node CPU/Memory" "WARNING" "70-90% 사용 - $detail"
        else
            report "Node CPU/Memory" "OK" "모든 노드 70% 이하"
        fi
        echo ""; echo "$top_filtered"
    fi
}

check_namespace_events() {
    print_hdr "네임스페이스별 K8S 이벤트 확인"
    TMP_REPORT=$(mktemp "${SCRIPT_TMPDIR}/tmp.XXXXXX")
    overall_warnings=0
    for ns in "${NAMESPACES[@]}"; do
        events=$(oc get event -n "$ns" --no-headers 2>&1 || true)
        # ignore Normal/transient
        events_filtered=$(echo "$events" | grep -v -E '^$' | grep -v -E '\bNormal\b' | grep -v -E '\btransient\b' || true)
        if echo "$events_filtered" | grep -q "No resources found" || [[ -z "${events_filtered//[[:space:]]/}" ]]; then
            printf "%-15s %-10s %s\n" "$ns" "[OK]" "이벤트 없음" >> "$TMP_REPORT"
            : > "${SCRIPT_TMPDIR}/event_${ns}_last24h.txt"
            continue
        fi
        echo "$events_filtered" > "${SCRIPT_TMPDIR}/event_${ns}_last24h.txt"
        overall_warnings=1
        warn_count=$(echo "$events_filtered" | sed '/^\s*$/d' | wc -l | tr -d ' ')
        if [[ $warn_count -gt 0 ]]; then
            printf "%-15s %-10s %s\n" "$ns" "[WARNING]" "${warn_count}건" >> "$TMP_REPORT"
        else
            printf "%-15s %-10s %s\n" "$ns" "[OK]" "이벤트 없음" >> "$TMP_REPORT"
        fi
    done
    if [[ $overall_warnings -eq 0 ]]; then
        report "Namespace Events" "OK" "모든 네임스페이스 정상"
    else
        local event_summary=$(cat "$TMP_REPORT" | grep WARNING | awk '{print $1":"$3}' | tr '\n' ' ' || true)
        report "Namespace Events" "WARNING" "경고 발견: $event_summary"
    fi
    printf "\n"; printf "%-15s %-10s %s\n" "NAMESPACE" "STATUS" "DETAILS"; printf "%s\n" "---------------------------------------------------------"
    cat "$TMP_REPORT"; rm -f "$TMP_REPORT"
}

check_namespace_pods() {
    print_hdr "네임스페이스별 파드 상태"
    TMP_POD_REPORT=$(mktemp "${SCRIPT_TMPDIR}/tmp.XXXXXX")
    overall_pod_issues=0
    for ns in "${NAMESPACES[@]}"; do
        pods_wide=$(oc get pod -n "$ns" -o wide --no-headers 2>/dev/null || true)
        pods_fmt=$(echo "$pods_wide" | awk 'NF>=5 {printf "%-36s %-6s %-10s %-8s %-4s\n", $1, $2, $3, $4, $5}')
        if [[ -z "${pods_fmt//[[:space:]]/}" ]]; then
            : > "${SCRIPT_TMPDIR}/pods_${ns}.txt"
        else
            printf "%-36s %-6s %-10s %-8s %-4s\n" "NAME" "READY" "STATUS" "RESTARTS" "AGE" > "${SCRIPT_TMPDIR}/pods_${ns}.txt"
            echo "$pods_fmt" >> "${SCRIPT_TMPDIR}/pods_${ns}.txt"
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
        report "Namespace Pods" "OK" "모든 파드 정상"
    else
        local pod_summary=$(cat "$TMP_POD_REPORT" | grep CRITICAL | awk '{print $1":"$3}' | tr '\n' ' ' || true)
        report "Namespace Pods" "CRITICAL" "이상 파드: $pod_summary"
    fi
    printf "\n"; printf "%-15s %-10s %s\n" "NAMESPACE" "STATUS" "DETAILS"; printf "%s\n" "---------------------------------------------------------"
    cat "$TMP_POD_REPORT"; echo ""
    for ns in "${NAMESPACES[@]}"; do
        pods_slim=$(cat "${SCRIPT_TMPDIR}/pods_${ns}.txt" 2>/dev/null || true)
        if [[ -z "${pods_slim//[[:space:]]/}" ]]; then
            echo "## $ns: (파드 정보 없음)"
        else
            echo "## $ns 네임스페이스 파드 목록"
            echo "$pods_slim"; echo ""
        fi
    done
    rm -f "$TMP_POD_REPORT"
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
    if [[ -z "${controller_pods//[[:space:]]/}" ]]; then
        report "Kafka Controller" "CRITICAL" "컨트롤러 파드 없음"
    else
        nonrun=$(echo "$controller_pods" | awk '$3 != "Running" {print $1}' || true)
        if [[ -z "${nonrun//[[:space:]]/}" ]]; then
            report "Kafka Controller" "OK" "모두 Running"
        else
            report "Kafka Controller" "CRITICAL" "비정상: $nonrun"
        fi
    fi
    oc get pod -n $NAMESPACE -l strimzi.io/controller-role=true || true

    echo ""; echo "[2] Kafka 브로커 상태 확인"
    broker_pods=$(oc get pod -n $NAMESPACE -l strimzi.io/broker-role=true --no-headers 2>/dev/null || true)
    if [[ -z "${broker_pods//[[:space:]]/}" ]]; then
        report "Kafka Broker" "CRITICAL" "브로커 파드 없음"
    else
        nonrunning_brokers=$(echo "$broker_pods" | awk '$3 != "Running" {print $1}' || true)
        if [[ -z "${nonrunning_brokers//[[:space:]]/}" ]]; then
            report "Kafka Broker" "OK" "모두 Running"
        else
            report "Kafka Broker" "CRITICAL" "비정상: $nonrunning_brokers"
        fi
    fi
    oc get pod -n $NAMESPACE -l strimzi.io/broker-role=true || true

    echo ""; echo "[3] Kafka 기타 서비스 상태"
    for sel in "app.kubernetes.io/name=entity-operator" "app.kubernetes.io/name=kafka-exporter" "name=strimzi-cluster-operator"; do
        echo "NAME: $sel"
        oc get pod -n $NAMESPACE -l "$sel" --no-headers 2>/dev/null | awk '{printf "%-42s %-6s %-10s %-10s %-6s\n", $1, $2, $3, $4, $5}' || true
    done

    echo ""; echo "[4] Consumer Group Lag 확인"
    for group in "${CONSUMER_GROUPS[@]}"; do
        echo "Consumer Group: $group"
        TMP1=$(mktemp "${SCRIPT_TMPDIR}/tmp.XXXXXX"); TMP2=$(mktemp "${SCRIPT_TMPDIR}/tmp.XXXXXX"); TMP3=$(mktemp "${SCRIPT_TMPDIR}/tmp.XXXXXX")
        get_lag_snapshot "$group" "$TMP1"
        sleep $INTERVAL
        get_lag_snapshot "$group" "$TMP2"
        sleep $INTERVAL
        get_lag_snapshot "$group" "$TMP3"
        printf "%-20s %-20s %-10s %-12s %-12s %-12s %-33s\n" "GROUP" "TOPIC" "PARTITION" "LAG-1" "LAG-2" "LAG-3" "CONSUMER-ID"
        paste $TMP1 $TMP2 $TMP3 | awk -F"\t" -v g="$group" '{t1=$1;p1=$2;l1=$3;c1=$4; t2=$5;p2=$6;l2=$7;c2=$8; t3=$9;p3=$10;l3=$11;c3=$12; if(t1==t2&&t2==t3&&p1==p2&&p2==p3){cid=(c1!=""?c1:(c2!=""?c2:c3)); printf "%-20s %-20s %-10s %-12s %-12s %-12s %-33s\n", g, t1, p1, l1, l2, l3, cid}}' || true
        rm -f $TMP1 $TMP2 $TMP3 || true
        echo ""
    done

    echo "[5] CDR 데이터 DB 적재 상태 체크"
    CDR_DB=$(oc exec -n nwdaf "${CH_POD:-clickhouse-shard0-0}" -- bash -c "clickhouse-client --password=\$CLICKHOUSE_ADMIN_PASSWORD -d nwdaf -q \"SELECT event_time, count(*) FROM stat_ipmdn_recv WHERE event_time > now() - toIntervalSecond(20) GROUP BY event_time ORDER BY event_time DESC LIMIT 5\"" 2>/dev/null || true)
    CDR_ROWS=$(echo "$CDR_DB" | sed '/^\s*$/d' | wc -l | tr -d ' ')
    if [[ -n "${CDR_DB//[[:space:]]/}" && "$CDR_ROWS" -ge 1 ]]; then
        report "CDR Data Ingestion" "OK" "최근 20초 내 적재 확인"
        echo "$CDR_DB" | sed 's/^/  /'
    else
        report "CDR Data Ingestion" "CRITICAL" "최근 데이터 없음 (rows: ${CDR_ROWS:-0})"
        echo "  (rows: ${CDR_ROWS:-0})"
    fi

    echo ""; echo "[6] TLS 인증서 만료일 점검"
    # 참조 명령어 대비 개선: BROKER_PODS 배열 재사용(추가 oc get pod 호출 불필요),
    # 컨트롤러(9090)/브로커(9091) 리스너 분리 점검
    TLS_CRIT=0
    NOW_EPOCH=$(date +%s)
    CERT_WARN_DAYS=30

    _kafka_tls_check() {
        local pod="$1" port="$2" role="$3"
        local end_raw exp_str exp_epoch days_left
        end_raw=$(oc exec "$pod" -n "$NAMESPACE" -c kafka -- bash -c \
            "echo | openssl s_client -connect localhost:${port} 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null" \
            2>/dev/null || true)
        if [[ -z "${end_raw//[[:space:]]/}" ]]; then
            printf "  [%-10s] %-45s => 인증서 조회 실패\n" "$role" "$pod"
            TLS_CRIT=1
            return
        fi
        exp_str=$(echo "$end_raw" | sed 's/notAfter=//')
        exp_epoch=$(date --date="$exp_str" +%s 2>/dev/null || echo 0)
        days_left=$(( (exp_epoch - NOW_EPOCH) / 86400 ))
        if [[ "$days_left" -le "$CERT_WARN_DAYS" ]]; then
            printf "  [%-10s] %-45s 만료: %-32s (D-%d) [CRITICAL]\n" "$role" "$pod" "$exp_str" "$days_left"
            TLS_CRIT=1
        else
            printf "  [%-10s] %-45s 만료: %-32s (D-%d)\n" "$role" "$pod" "$exp_str" "$days_left"
        fi
    }

    # Controller 파드 점검 (port 9090: KRaft controller listener)
    ctrl_pod_list=$(oc get pod -n "$NAMESPACE" -l strimzi.io/controller-role=true --no-headers 2>/dev/null \
        | awk '{print $1}' || true)
    if [[ -z "${ctrl_pod_list//[[:space:]]/}" ]]; then
        echo "  (컨트롤러 파드 없음 - 인증서 점검 불가)"
        TLS_CRIT=1
    else
        for pod in $ctrl_pod_list; do
            _kafka_tls_check "$pod" 9090 "Controller"
        done
    fi

    # Broker 파드 점검 (port 9091: inter-broker replication listener)
    # BROKER_PODS 배열 재사용 - 함수 초반에 이미 조회 완료
    if [[ ${#BROKER_PODS[@]} -eq 0 ]]; then
        echo "  (브로커 파드 없음 - 인증서 점검 불가)"
        TLS_CRIT=1
    else
        for pod in "${BROKER_PODS[@]}"; do
            _kafka_tls_check "$pod" 9091 "Broker"
        done
    fi

    if [[ "$TLS_CRIT" -eq 0 ]]; then
        report "Kafka TLS Cert" "OK" "모든 인증서 ${CERT_WARN_DAYS}일 초과 여유"
    else
        report "Kafka TLS Cert" "CRITICAL" "만료 ${CERT_WARN_DAYS}일 이내 인증서 존재 또는 조회 실패"
    fi
}

check_prb() {
    print_hdr "IDCUBE Datagw 연동 (PRB 데이터) 점검"
    echo "[1] datagw cronjob 상태 체크"
    datagw_jobs=$(oc get pod -n nwdaf | grep datagw | grep -E 'Error' || true)
    if [[ -z "$datagw_jobs" ]]; then
        report "PRB Datagw Jobs" "OK" "Error 상태 job 없음"
    else
        report "PRB Datagw Jobs" "CRITICAL" "Error job 발견: $datagw_jobs"
    fi
    echo ""; datagw_pods_full=$(oc get pod -n nwdaf | grep datagw 2>&1 || true)
    if [[ -z "${datagw_pods_full//[[:space:]]/}" ]]; then echo "    (datagw 파드 정보 없음)"; else echo "$datagw_pods_full" | sed 's/^/  /'; fi
    
    echo ""
    echo "[2] PRB 데이터 DB 적재 상태 체크"
    PRB_4G_RAW=$(oc exec -n nwdaf "${CH_POD:-clickhouse-shard0-0}" -- bash -c "clickhouse-client --password=\$CLICKHOUSE_ADMIN_PASSWORD -d nwdaf -q \"SELECT event_date, count() FROM t_4g_cell_prb_5m WHERE event_date >= now() - INTERVAL 1 hour GROUP BY event_date ORDER BY event_date LIMIT 5\"" 2>/dev/null || true)
    PRB_5G_RAW=$(oc exec -n nwdaf "${CH_POD:-clickhouse-shard0-0}" -- bash -c "clickhouse-client --password=\$CLICKHOUSE_ADMIN_PASSWORD -d nwdaf -q \"SELECT event_date, count() FROM t_5g_cell_prb_15m WHERE event_date >= now() - INTERVAL 1 hour GROUP BY event_date ORDER BY event_date LIMIT 5\"" 2>/dev/null || true)
    # event_date가 날짜+시간으로 분리되어 3개 필드로 출력됨: 날짜 시간 count
    PRB_4G_SUM=$(echo "$PRB_4G_RAW" | awk '{s+=($3+0)} END{print s+0}')
    PRB_5G_SUM=$(echo "$PRB_5G_RAW" | awk '{s+=($3+0)} END{print s+0}')
    if [[ ${PRB_4G_SUM:-0} -ge 1 && ${PRB_5G_SUM:-0} -ge 1 ]]; then 
        report "PRB Data 4G/5G" "OK" "최근 1시간 내 적재 (4G:$PRB_4G_SUM, 5G:$PRB_5G_SUM)"
    else 
        report "PRB Data 4G/5G" "CRITICAL" "데이터 부족 (4G:$PRB_4G_SUM, 5G:$PRB_5G_SUM)"
    fi
    echo ""; echo "PRB_4G:"; if [[ -z "${PRB_4G_RAW//[[:space:]]/}" ]]; then echo "  없음"; else echo "$PRB_4G_RAW" | sed 's/^/  /'; fi
    echo ""; echo "PRB_5G:"; if [[ -z "${PRB_5G_RAW//[[:space:]]/}" ]]; then echo "  없음"; else echo "$PRB_5G_RAW" | sed 's/^/  /'; fi
}

check_cmsweb() {
    print_hdr "CMSWEB 연동 점검"
    echo "[1] cmsweb-ftp-server 파드 상태 체크"
    cmsweb_cmsweb_pods=$(oc get pod -n nwdaf | grep cmsweb | awk '$3 != "Running" {print $1}' || true)
    if [[ -z "$cmsweb_cmsweb_pods" ]]; then
        report "CMSWEB FTP Server" "OK" "primary/secondary Running"
    else
        report "CMSWEB FTP Server" "CRITICAL" "비정상: $cmsweb_cmsweb_pods"
    fi
    echo ""
    ftp_pods_output=$(oc get pod -n nwdaf -l app=ftp-server 2>&1 || true)
    if [[ -z "${ftp_pods_output//[[:space:]]/}" ]]; then
        echo "  (ftp-server 파드 정보 없음)"
    else
        echo "$ftp_pods_output" | sed 's/^/  /'
    fi

    echo ""
    echo "[2] cmsweb 기지국 데이터 DB 업데이트 체크"
    DB_UPD_RAW=$(oc exec -n nwdaf "${CH_POD:-clickhouse-shard0-0}" -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT max(update_time) FROM conn_pgsql_mv_t_cell_lte_all"' 2>/dev/null || true)
    DB_UPD_UTC=$(echo "$DB_UPD_RAW" | grep -v 'Defaulted container' | sed -n '/\S/,$p' | tail -n1 | tr -d '\r')
    
    # 판정 코멘트 먼저 출력
    if [[ -z "$DB_UPD_UTC" ]]; then
        report "CMSWEB Update" "CRITICAL" "업데이트 정보 없음"
    else
        DB_TIMESTAMP=$(TZ=UTC date --date="$DB_UPD_UTC" +%s 2>/dev/null || echo 0)
        NOW_TIMESTAMP=$(TZ=UTC date +%s)
        ONE_HOUR_AGO=$((NOW_TIMESTAMP - 3600))
        THREE_HOURS_AGO=$((NOW_TIMESTAMP - 10800))
        
        if [[ $DB_TIMESTAMP -ge $ONE_HOUR_AGO ]]; then
            report "CMSWEB Update" "OK" "최근 1시간 내 업데이트"
        elif [[ $DB_TIMESTAMP -ge $THREE_HOURS_AGO ]]; then
            report "CMSWEB Update" "WARNING" "1~3시간 전 업데이트"
        else
            report "CMSWEB Update" "CRITICAL" "3시간 이상 미업데이트"
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
        report "Policysender Pods" "OK" "2개 파드 Running"
    elif [[ "$running_count" -eq 1 ]]; then
        report "Policysender Pods" "WARNING" "1개 파드만 Running"
    else
        report "Policysender Pods" "CRITICAL" "Running 파드 없음"
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
        report "Policysender Logs" "OK" "Warn/Error 로그 없음"
    else
        report "Policysender Logs" "WARNING" "Warn/Error 로그 발견"
    fi
}

check_ai() {
    print_hdr "학습/추론 점검"
    echo "[1] 파이프라인 Pod 상태 체크"
    runof_jobs=$(oc get pod -n nwdaf | grep runof | grep -E 'Error' || true)
    if [[ -z "$runof_jobs" ]]; then 
        report "AI Training Jobs" "OK" "Error 상태 job 없음"
    else 
        report "AI Training Jobs" "CRITICAL" "Error job: $runof_jobs"
    fi

    echo ""
    echo "[2] 추론 결과 데이터 적재 상태 체크"
    PRED_PRB=$(oc exec -n nwdaf "${CH_POD:-clickhouse-shard0-0}" -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT window_end, model_type, count() FROM ai.t_cell_prb_usage_predicted WHERE model_type = '\''prb'\'' GROUP BY window_end, model_type ORDER BY window_end DESC LIMIT 10"' 2>/dev/null || true)
    PRED_PRB_ROWS=$(echo "$PRED_PRB" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    # window_end가 날짜+시간으로 분리되어 4개 필드로 출력됨: 날짜 시간 model_type count
    PRED_PRB_SUM=$(echo "$PRED_PRB" | awk 'NF>=4 {s+=($4+0)} END{print s+0}')
    PRED_NOW_TS=$(TZ=UTC date +%s)
    FIVE_MIN_AGO=$((PRED_NOW_TS - 300))
    PRED_PRB_LATEST_DT=$(echo "$PRED_PRB" | awk 'NR==1 && NF>=4 {print $1" "$2}')
    PRED_PRB_RECENT=0
    if [[ -n "$PRED_PRB_LATEST_DT" ]]; then
        PRED_PRB_LATEST_TS=$(TZ=UTC date --date="$PRED_PRB_LATEST_DT" +%s 2>/dev/null || echo 0)
        [[ $PRED_PRB_LATEST_TS -ge $FIVE_MIN_AGO ]] && PRED_PRB_RECENT=1
    fi
    if [[ -n "${PRED_PRB//[[:space:]]/}" && "$PRED_PRB_ROWS" -ge 1 && "$PRED_PRB_SUM" -ge 1 && "$PRED_PRB_RECENT" -eq 1 ]]; then 
        report "AI PRB Raw Data" "OK" "최근 5분 내 적재 확인"
    elif [[ -n "${PRED_PRB//[[:space:]]/}" && "$PRED_PRB_ROWS" -ge 1 && "$PRED_PRB_SUM" -ge 1 ]]; then
        report "AI PRB Raw Data" "WARNING" "5분 내 신규 적재 없음 (최근: $PRED_PRB_LATEST_DT)"
    else 
        report "AI PRB Raw Data" "CRITICAL" "추론 결과 없음"
    fi
    if [[ -n "${PRED_PRB//[[:space:]]/}" ]]; then echo "$PRED_PRB" | sed 's/^/  /'; fi

    PRED_XGB=$(oc exec -n nwdaf "${CH_POD:-clickhouse-shard0-0}" -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT window_end, model_type, count() FROM ai.t_cell_prb_usage_predicted WHERE model_type = '\''xgboost'\'' GROUP BY window_end, model_type ORDER BY window_end DESC LIMIT 10"' 2>/dev/null || true)
    PRED_XGB_ROWS=$(echo "$PRED_XGB" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    # window_end가 날짜+시간으로 분리되어 4개 필드로 출력됨: 날짜 시간 model_type count
    PRED_XGB_SUM=$(echo "$PRED_XGB" | awk 'NF>=4 {s+=($4+0)} END{print s+0}')
    PRED_XGB_LATEST_DT=$(echo "$PRED_XGB" | awk 'NR==1 && NF>=4 {print $1" "$2}')
    PRED_XGB_RECENT=0
    if [[ -n "$PRED_XGB_LATEST_DT" ]]; then
        PRED_XGB_LATEST_TS=$(TZ=UTC date --date="$PRED_XGB_LATEST_DT" +%s 2>/dev/null || echo 0)
        [[ $PRED_XGB_LATEST_TS -ge $FIVE_MIN_AGO ]] && PRED_XGB_RECENT=1
    fi
    if [[ -n "${PRED_XGB//[[:space:]]/}" && "$PRED_XGB_ROWS" -ge 1 && "$PRED_XGB_SUM" -ge 1 && "$PRED_XGB_RECENT" -eq 1 ]]; then 
        report "AI XGBoost Infer Result" "OK" "최근 5분 내 적재 확인"
    elif [[ -n "${PRED_XGB//[[:space:]]/}" && "$PRED_XGB_ROWS" -ge 1 && "$PRED_XGB_SUM" -ge 1 ]]; then
        report "AI XGBoost Infer Result" "WARNING" "5분 내 신규 적재 없음 (최근: $PRED_XGB_LATEST_DT)"
    else 
        report "AI XGBoost Infer Result" "CRITICAL" "추론 결과 없음"
    fi
    if [[ -n "${PRED_XGB//[[:space:]]/}" ]]; then echo "$PRED_XGB" | sed 's/^/  /'; fi

    echo ""
    echo "[3] 추론용 데이터셋 적재 상태 체크"
    INFER_DATA=$(oc exec -n nwdaf "${CH_POD:-clickhouse-shard0-0}" -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT window_end, count() FROM ai.cell_data_infer WHERE window_end >= now() - toIntervalMinute(2) GROUP BY 1 ORDER BY 1 DESC"' 2>/dev/null || true)
    INFER_ROWS=$(echo "$INFER_DATA" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    if [[ -n "${INFER_DATA//[[:space:]]/}" && "$INFER_ROWS" -ge 1 ]]; then
        report "AI Inference Dataset" "OK" "최근 2분 내 데이터 확인"
        echo "$INFER_DATA" | sed 's/^/  /'
    else
        report "AI Inference Dataset" "CRITICAL" "최근 2분 내 데이터 없음"
    fi

    echo ""
    echo "[4] 학습용 데이터셋 적재 상태 체크"
    # LIMIT 8 = 최신 4개 window x (lte, 5g) 2종 -> 직전 완결 window 판정 및 최근 추이 확인에 충분
    TRAIN_INFER_DATA=$(oc exec -n nwdaf "${CH_POD:-clickhouse-shard0-0}" -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT window_end, cell_type, count() FROM ai.cell_usage_infer_5m GROUP BY 1, 2 ORDER BY 1 DESC, 2 DESC LIMIT 8"' 2>/dev/null || true)
    # window_end가 날짜+시간으로 분리되어 출력됨: 날짜 시간 cell_type count
    TRAIN_INFER_ROWS=$(echo "$TRAIN_INFER_DATA" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    if [[ -n "${TRAIN_INFER_DATA//[[:space:]]/}" && "$TRAIN_INFER_ROWS" -ge 1 ]]; then
        LATEST_DT=$(echo "$TRAIN_INFER_DATA" | awk 'NR==1 && NF>=4 {print $1" "$2}')
        IS_RECENT=0
        if [[ -n "$LATEST_DT" ]]; then
            LATEST_TS=$(TZ=UTC date --date="$LATEST_DT" +%s 2>/dev/null || echo 0)
            NOW_TS=$(TZ=UTC date +%s)
            EIGHTY_MIN_AGO=$((NOW_TS - 4800))
            [[ $LATEST_TS -ge $EIGHTY_MIN_AGO ]] && IS_RECENT=1
        fi
        HAS_LTE=$(echo "$TRAIN_INFER_DATA" | awk 'NF>=3 && $3=="lte" {found=1} END{print found+0}')
        HAS_5G=$(echo "$TRAIN_INFER_DATA" | awk 'NF>=3 && $3=="5g" {found=1} END{print found+0}')
        # 5g는 lte보다 다소 늦게 생성될 수 있으므로 가장 최신 window는 grace 처리하고,
        # 직전 완결 window(PREV_DT)에 lte/5g가 함께 있는지로 5g 5분 주기 적재를 판정
        PREV_DT=$(echo "$TRAIN_INFER_DATA" | awk -v d="$LATEST_DT" 'NF>=4 {w=$1" "$2; if(w!=d){print w; exit}}')
        PREV_HAS_LTE=$(echo "$TRAIN_INFER_DATA" | awk -v d="$PREV_DT" 'NF>=4 && ($1" "$2)==d && $3=="lte" {found=1} END{print found+0}')
        PREV_HAS_5G=$(echo "$TRAIN_INFER_DATA" | awk -v d="$PREV_DT" 'NF>=4 && ($1" "$2)==d && $3=="5g" {found=1} END{print found+0}')
        if [[ "$IS_RECENT" -eq 1 && "$HAS_LTE" -eq 1 && "$HAS_5G" -eq 1 && "$PREV_HAS_LTE" -eq 1 && "$PREV_HAS_5G" -eq 1 ]]; then
            report "AI TrainDataset" "OK" "80분 내 lte/5g 데이터 확인 (5g 5분 주기 적재 정상)"
        else
            ti_detail=""
            [[ "$IS_RECENT" -eq 0 ]] && ti_detail="최근 80분 내 데이터 없음"
            [[ "$HAS_LTE" -ne 1 ]] && ti_detail="${ti_detail:+$ti_detail, }lte 데이터 없음"
            [[ "$HAS_5G" -ne 1 ]] && ti_detail="${ti_detail:+$ti_detail, }5g 데이터 없음"
            # 직전 완결 window에도 5g가 빠진 경우 -> 단순 지연이 아니라 5g 5분 주기 이상으로 판정
            [[ "$HAS_5G" -eq 1 && "$PREV_HAS_5G" -ne 1 ]] && ti_detail="${ti_detail:+$ti_detail, }직전 5분 window에 5g 미적재 (5g 5분 주기 이상)"
            [[ "$HAS_LTE" -eq 1 && "$PREV_HAS_LTE" -ne 1 ]] && ti_detail="${ti_detail:+$ti_detail, }직전 5분 window에 lte 미적재"
            report "AI TrainDataset" "CRITICAL" "$ti_detail"
        fi
        echo "$TRAIN_INFER_DATA" | sed 's/^/  /'
    else
        report "AI TrainDataset" "CRITICAL" "데이터 없음"
    fi

    echo ""
    echo "[5] 학습 히스토리 조회"
    model_seq_result=$(oc exec -n nwdaf "${CH_POD:-clickhouse-shard0-0}" -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf -q "SELECT model_type, excution_end, model_seq, cell_count, train_result FROM ai.model_train_hist ORDER BY model_seq DESC LIMIT 20"' 2>/dev/null || true)
    echo "$model_seq_result" | grep Success || true

    echo ""
    echo "[6] 모델 히스토리 및 파일 점검"
    minio_hist=$(oc exec -n kubeflow minio-nwdaf-0 -- sh -c "mc ls local/model-repo-history" 2>/dev/null || true)
    if [[ -z "${minio_hist//[[:space:]]/}" ]]; then 
        report "MinIO Model History" "CRITICAL" "히스토리 파일 없음"
    else 
        report "MinIO Model History" "OK" "히스토리 파일 존재"
    fi

    xgboost_files=$(oc exec -n kubeflow minio-nwdaf-0 -c minio -- sh -c "mc ls --recursive local/model-repo/xgboost_model" 2>/dev/null || true)

    if [[ -z "${xgboost_files//[[:space:]]/}" ]]; then
        echo "=> XGBoost 모델 파일 미존재 [CRITICAL]"
        report "MinIO Model Files" "CRITICAL" "XGBoost 파일 없음"
    else
        echo "=> XGBoost 모델 파일 존재 확인 [OK]"
        report "MinIO Model Files" "OK" "XGBoost 파일 존재"
    fi
}

check_db_disk() {
    print_hdr "DB/Disk 사용량 점검"
    
    echo "[1] PostgreSQL 데이터베이스 용량"
    # PostgreSQL DB 크기 확인
    POSTGRES_NS=nwdaf
    POSTGRES_POD=$(oc get pod -n $POSTGRES_NS --no-headers | grep cloudnative-pg-cluster | awk 'NR==1{print $1}' || true)
    if [[ -n "$POSTGRES_POD" ]]; then
        # MAX bytes + pretty format을 한 번의 exec로 조회 (exec 3회 → 2회)
        postgres_max_row=$(oc exec -n $POSTGRES_NS $POSTGRES_POD -- psql -U postgres -t -A -F'|' -c \
            "SELECT MAX(pg_database_size(datname)), pg_size_pretty(MAX(pg_database_size(datname))) FROM pg_database;" \
            2>/dev/null || echo "0|0 bytes")
        postgres_max_bytes=$(echo "$postgres_max_row" | cut -d'|' -f1)
        postgres_max_pretty=$(echo "$postgres_max_row" | cut -d'|' -f2)
        postgres_space=$(oc exec -n $POSTGRES_NS $POSTGRES_POD -- psql -U postgres -c \
            "SELECT datname AS db_name, pg_size_pretty(pg_database_size(datname)) AS used FROM pg_database ORDER BY pg_database_size(datname) DESC;" \
            2>/dev/null || true)
        
        # 판정 코멘트 먼저 출력 (1GB = 1073741824 bytes)
        if [[ ${postgres_max_bytes:-0} -gt 1073741824 ]]; then
            report "PostgreSQL DB Size" "WARNING" "최대 DB ${postgres_max_pretty} 사용 중"
        else
            report "PostgreSQL DB Size" "OK" "모든 DB 1GB 이하"
        fi
        # 실제 데이터 출력 (헤더 명시적 추가)
        echo ""
        printf "%-30s %15s\n" "DATABASE" "SIZE"
        printf "%s\n" "-----------------------------------------------"
        # psql 출력에서 헤더(2줄)와 footer(1줄) 제거 후 데이터만 출력
        echo "$postgres_space" | tail -n +3 | head -n -1 | awk '{printf "%-30s %15s\n", $1, $3" "$4}' || true
    else
        echo "[PostgreSQL 파드를 찾을 수 없습니다.] [CRITICAL]"
        report "PostgreSQL DB Size" "CRITICAL" "파드 없음"
    fi

    echo ""
    echo "[2] ClickHouse 테이블스페이스 및 디스크"
    # ClickHouse 테이블스페이스 및 디스크 여유공간
    CLICKHOUSE_NS=nwdaf; CLICKHOUSE_POD=${CH_POD:-clickhouse-shard0-0}
    if oc get pod -n $CLICKHOUSE_NS $CLICKHOUSE_POD &>/dev/null; then
        echo ""
        echo "## ClickHouse 테이블스페이스 사용량"
        clickhouse_space=$(oc exec -n $CLICKHOUSE_NS $CLICKHOUSE_POD -- bash -c "clickhouse-client --password=\$CLICKHOUSE_ADMIN_PASSWORD --query \"SELECT database, formatReadableSize(sum(bytes)) AS used, any(disk_name) AS disk FROM system.parts WHERE active GROUP BY database ORDER BY sum(bytes) DESC;\"" 2>/dev/null || true)
        
        # 판정 코멘트 먼저 출력 (2TiB = 2048 GiB) - TiB, GiB, MiB 모두 처리 (ClickHouse는 헤더 없음)
        total_gib=$(echo "$clickhouse_space" | awk '
            NF >= 3 {
                val = $2 + 0
                unit = $3
                if (unit == "TiB") gib = val * 1024
                else if (unit == "GiB") gib = val
                else if (unit == "MiB") gib = val / 1024
                else gib = 0
                total += gib
            }
            END {print total + 0}
        ')
        if awk -v total="$total_gib" 'BEGIN {exit (total > 2048) ? 0 : 1}'; then
            report "ClickHouse Table Size" "WARNING" "전체 ${total_gib}GiB 사용 중 (2TiB 초과)"
        else
            report "ClickHouse Table Size" "OK" "전체 ${total_gib}GiB 사용 중"
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
            report "ClickHouse Disk Space" "WARNING" "여유 공간 ${free_display} (${free_gib}GiB) - 50GiB 미만"
        else
            report "ClickHouse Disk Space" "OK" "여유 공간 ${free_display:-충분} (${free_gib}GiB)"
        fi
        
        # 실제 데이터 출력 (헤더 강조)
        echo ""
        printf "%-15s %-35s %15s %15s\n" "DISK_NAME" "PATH" "FREE_SPACE" "TOTAL_SPACE"
        printf "%s\n" "--------------------------------------------------------------------------------"
        # ClickHouse는 기본적으로 헤더를 출력하지 않으므로 전체 출력
        echo "$clickhouse_disk" | grep -v '^$' | awk '{printf "%-15s %-35s %15s %15s\n", $1, $2, $3" "$4, $5" "$6}' || true
    else
        echo "[ClickHouse 파드를 찾을 수 없습니다.] [CRITICAL]"
        report "ClickHouse Disk Space" "CRITICAL" "파드 없음"
    fi
}

check_ui_connection() {
    print_hdr "ITM UI CONNECTION CHECK"
    
    echo "[1] 파드 상태 확인"
    UI_NS=nwdaf
    # api-gateway, frontend, backend 파드 조회
    pods_status=$(oc get pod -n $UI_NS --no-headers 2>/dev/null | grep -E "api-gateway|frontend|backend" || true)
    
    if [[ -z "$pods_status" ]]; then
        report "UI Pods Status" "CRITICAL" "파드 없음"
    else
        not_running=$(echo "$pods_status" | awk '$3 != "Running" {print $1, $3}' || true)
        
        if [[ -z "$not_running" ]]; then
            report "UI Pods Status" "OK" "모든 파드 Running"
        else
            report "UI Pods Status" "WARNING" "비정상 파드 존재"
        fi
        
        echo ""
        printf "%-45s %-12s %s\n" "NAME" "STATUS" "RESTARTS"
        printf "%s\n" "----------------------------------------------------------------------"
        echo "$pods_status" | awk '{printf "%-45s %-12s %s\n", $1, $3, $4}'
    fi
    
    echo ""
    echo "[2] 서비스 상태 확인"
    # api-gateway 관련 서비스 조회 (api-gateway, api-gateway-150 모두 포함)
    svc_status=$(oc get svc -n $UI_NS --no-headers 2>/dev/null | grep api-gateway || true)
    external_ip=""
    gw_svc=""

    if [[ -z "$svc_status" ]]; then
        report "UI Service Status" "CRITICAL" "서비스 없음"
    else
        echo ""
        printf "%-30s %-15s %-20s %-20s %s\n" "NAME" "TYPE" "CLUSTER-IP" "EXTERNAL-IP" "PORT(S)"
        printf "%s\n" "---------------------------------------------------------------------------------------------"
        echo "$svc_status" | awk '{printf "%-30s %-15s %-20s %-20s %s\n", $1, $2, $3, $4, $5}'
        echo ""

        # 서비스별 개별 상태 판정
        while IFS= read -r svc_line; do
            [[ -z "$svc_line" ]] && continue
            s_name=$(echo "$svc_line" | awk '{print $1}')
            s_type=$(echo "$svc_line" | awk '{print $2}')
            s_ip=$(echo "$svc_line" | awk '{print $4}')
            if [[ "$s_type" == "LoadBalancer" ]] && [[ -n "$s_ip" ]] && [[ "$s_ip" != "<pending>" ]] && [[ "$s_ip" != "<none>" ]]; then
                report "UI Svc($s_name)" "OK" "LoadBalancer EXTERNAL-IP: $s_ip"
            elif [[ "$s_type" != "LoadBalancer" ]]; then
                report "UI Svc($s_name)" "WARNING" "타입: $s_type"
            else
                report "UI Svc($s_name)" "WARNING" "EXTERNAL-IP 미할당"
            fi
        done <<< "$svc_status"

        # 접속 테스트 기준: api-gateway (word boundary 매칭, 150 제외)
        gw_svc=$(echo "$svc_status" | grep -w api-gateway | head -1 || echo "$svc_status" | head -1)
        external_ip=$(echo "$gw_svc" | awk '{print $4}')
    fi
    
    echo ""
    echo "[3] HTTPS 웹 접속 확인"
    # EXTERNAL-IP가 있으면 웹 접속 테스트
    if [[ -n "${external_ip:-}" ]] && [[ "$external_ip" != "<pending>" ]] && [[ "$external_ip" != "<none>" ]]; then
        # 서비스에서 포트 추출 (api-gateway 기준)
        port=$(echo "$gw_svc" | awk '{print $5}' | grep -oP '^\d+' || echo "30990")
        test_url="https://${external_ip}:${port}"
        
        echo "접속 테스트 URL: $test_url"
        
        # 재시도 로직 포함 (최대 2회 시도)
        http_code="000"
        curl_err_file=$(mktemp "${SCRIPT_TMPDIR}/tmp.XXXXXX")
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
            report "UI Web Access" "OK" "HTTP $http_code"
        elif [[ "$http_code" == "000" ]]; then
            report "UI Web Access" "CRITICAL" "연결 실패"
        else
            report "UI Web Access" "WARNING" "HTTP $http_code"
        fi
    else
        report "UI Web Access" "WARNING" "EXTERNAL-IP 없음"
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

exit 0
