#!/bin/bash

# 설정 변수
NAMESPACE="${NAMESPACE:-nwdaf}"
POD_NAME="${POD_NAME:-clickhouse-shard0-0}"
DB_NAME="system"

# 대상 테이블 리스트
TABLES=("trace_log" "part_log" "processors_profile_log" "query_log" "query_views_log" "asynchronous_metric_log" "metric_log" "text_log" "error_log")

# 월 단위 완료 후 mutation 완료 대기 최대 시간(초) - 이 시간 안에 완료되지 않으면 경고 후 다음 파티션으로 진행
MUTATION_WAIT_MAX="${MUTATION_WAIT_MAX:-300}"
MUTATION_WAIT_INTERVAL=5

# 사용법 출력
if [ $# -ne 2 ]; then
    echo "사용법: $0 <시작파티션> <종료파티션>"
    echo "예제: $0 202505 202507"
    echo "      $0 202504 202602  # 연도를 넘어가는 범위 가능"
    exit 1
fi

START_PARTITION="$1"
END_PARTITION="$2"

# 파티션 형식 검증 (YYYYMM)
if ! [[ "$START_PARTITION" =~ ^[0-9]{6}$ ]] || ! [[ "$END_PARTITION" =~ ^[0-9]{6}$ ]]; then
    echo "❌ 오류: 파티션은 YYYYMM 형식이어야 합니다 (예: 202505)"
    exit 1
fi

# 시작이 종료보다 큰지 확인
if [ "$START_PARTITION" -gt "$END_PARTITION" ]; then
    echo "❌ 오류: 시작 파티션이 종료 파티션보다 큽니다."
    exit 1
fi

# 사전 체크: oc 명령어 존재 확인
if ! command -v oc &> /dev/null; then
    echo "❌ 오류: 'oc' 명령어를 찾을 수 없습니다. OpenShift CLI를 설치해주세요."
    exit 1
fi

# 파드 접근 가능 여부 확인
if ! oc get pod -n "$NAMESPACE" "$POD_NAME" &> /dev/null; then
    echo "❌ 오류: 파드 '$POD_NAME'에 접근할 수 없습니다. (Namespace: $NAMESPACE)"
    exit 1
fi

# 이전 에러 로그 초기화
rm -f /tmp/clickhouse_drop_errors.log

echo "--------------------------------------------------------"
echo "ClickHouse 파티션 삭제 작업을 시작합니다."
echo "대상 파드: $POD_NAME (Namespace: $NAMESPACE)"
echo "삭제 범위: $START_PARTITION ~ $END_PARTITION"
echo "월 완료 후 mutation 대기 최대: ${MUTATION_WAIT_MAX}초"
echo "--------------------------------------------------------"

# 파티션 목록 생성 함수
generate_partitions() {
    local start=$1
    local end=$2
    local start_year=${start:0:4}
    local start_month=${start:4:2}
    local end_year=${end:0:4}
    local end_month=${end:4:2}
    
    local current_year=$start_year
    local current_month=$((10#$start_month))
    
    while [ "$current_year$current_month" != "$end_year$((10#$end_month + 1))" ]; do
        printf "%04d%02d\n" $current_year $current_month
        
        current_month=$((current_month + 1))
        if [ $current_month -gt 12 ]; then
            current_month=1
            current_year=$((current_year + 1))
        fi
    done
}

# 파티션 목록 생성
PARTITION_LIST=($(generate_partitions "$START_PARTITION" "$END_PARTITION"))

# 테이블 리스트 (SQL IN 절용)
TABLE_LIST_SQL="'trace_log','part_log','processors_profile_log','query_log','query_views_log','asynchronous_metric_log','metric_log','text_log','error_log'"

echo "삭제할 파티션 목록: ${PARTITION_LIST[@]}"
echo ""

# 월 단위로 처리 (파티션 우선 → 테이블 순서)
for PARTITION in "${PARTITION_LIST[@]}"; do
    echo "========================================================"
    echo "[파티션: $PARTITION] 처리 시작"
    echo "========================================================"

    MONTH_SUCCESS=0
    MONTH_ERROR=0

    for TABLE in "${TABLES[@]}"; do
        echo -n "  -> $TABLE: "

        RESULT=""
        RETRY_COUNT=0
        MAX_RETRY=3
        CMD_SUCCESS=false

        while [ $RETRY_COUNT -lt $MAX_RETRY ]; do
            RESULT=$(oc exec -n "$NAMESPACE" "$POD_NAME" -- bash -c \
                "clickhouse-client --password \${CLICKHOUSE_ADMIN_PASSWORD} -d $DB_NAME -q \"ALTER TABLE $TABLE ON CLUSTER default DROP PARTITION '$PARTITION'\"" 2>&1)

            if [ $? -eq 0 ]; then
                CMD_SUCCESS=true
                break
            elif echo "$RESULT" | grep -q "error dialing backend\|use of closed network connection"; then
                RETRY_COUNT=$((RETRY_COUNT + 1))
                if [ $RETRY_COUNT -lt $MAX_RETRY ]; then
                    sleep 2
                fi
            else
                break
            fi
        done

        if [ "$CMD_SUCCESS" = true ]; then
            # 파티션이 실제로 제거될 때까지 대기 (최대 120초)
            VERIFY_WAIT=0
            VERIFY_MAX=120
            VERIFY_INTERVAL=5
            while [ $VERIFY_WAIT -lt $VERIFY_MAX ]; do
                PART_COUNT=$(oc exec -n "$NAMESPACE" "$POD_NAME" -- bash -c \
                    "clickhouse-client --password \${CLICKHOUSE_ADMIN_PASSWORD} -d system -q \
                    \"SELECT count() FROM system.parts WHERE database='system' AND table='$TABLE' AND partition='$PARTITION' AND active=1\"" 2>/dev/null)
                if [ "${PART_COUNT:-1}" = "0" ]; then
                    break
                fi
                sleep $VERIFY_INTERVAL
                VERIFY_WAIT=$((VERIFY_WAIT + VERIFY_INTERVAL))
            done

            if [ $VERIFY_WAIT -ge $VERIFY_MAX ]; then
                echo "⚠️  DROP 성공 / 파티션 반영 타임아웃 (${VERIFY_MAX}s)"
                echo "[WARN] $TABLE:$PARTITION - DROP 명령 성공했으나 파티션 제거 확인 타임아웃 (${VERIFY_MAX}s)" >> /tmp/clickhouse_drop_errors.log
            else
                echo "OK (${VERIFY_WAIT}s)"
            fi
            ((MONTH_SUCCESS++))
        else
            # 파티션이 이미 없는 경우는 무시
            if echo "$RESULT" | grep -q "NO_SUCH_DATA_PART\|UNKNOWN_TABLE"; then
                echo "SKIP (파티션 없음)"
            else
                echo "ERROR"
                ((MONTH_ERROR++))
                echo "[ERROR] $TABLE:$PARTITION - $RESULT" >> /tmp/clickhouse_drop_errors.log
            fi
        fi
    done

    echo "--------------------------------------------------------"
    echo "  [$PARTITION] 월 완료 (성공: $MONTH_SUCCESS, 에러: $MONTH_ERROR)"
    echo "  미완료 mutation 확인 중..."

    MUTATION_WAITED=0
    while [ $MUTATION_WAITED -lt $MUTATION_WAIT_MAX ]; do
        PENDING=$(oc exec -n "$NAMESPACE" "$POD_NAME" -- bash -c \
            "clickhouse-client --password \${CLICKHOUSE_ADMIN_PASSWORD} -d system -q \
            \"SELECT count() FROM system.mutations WHERE database='system' AND table IN ($TABLE_LIST_SQL) AND is_done=0\"" 2>/dev/null)
        if [ "${PENDING:-0}" = "0" ]; then
            echo "  mutation 완료 확인 (대기: ${MUTATION_WAITED}초)"
            break
        fi
        echo "  미완료 mutation ${PENDING}개 대기 중... (${MUTATION_WAITED}s/${MUTATION_WAIT_MAX}s)"
        sleep $MUTATION_WAIT_INTERVAL
        MUTATION_WAITED=$((MUTATION_WAITED + MUTATION_WAIT_INTERVAL))
    done

    if [ $MUTATION_WAITED -ge $MUTATION_WAIT_MAX ]; then
        echo "  ⚠️  mutation 대기 타임아웃 (${MUTATION_WAIT_MAX}s) - 다음 파티션으로 진행합니다."
        echo "[WARN] $PARTITION - mutation 타임아웃, 미완료 mutation이 남아 있을 수 있음" >> /tmp/clickhouse_drop_errors.log
    fi
    echo "--------------------------------------------------------"
    echo ""
done
echo ""

sleep 2

echo "--------------------------------------------------------"
echo "[최종 상태 보고] 각 테이블별 가장 오래된 데이터 확인"
echo "--------------------------------------------------------"

# 확인 대상 테이블 리스트 (SQL 용) - 스크립트 상단에서 선언됨
# 테이블별 최소 파티션 및 용량 확인 쿼리
CHECK_MIN_QUERY="SELECT table, min(partition) as oldest, formatReadableSize(sum(bytes_on_disk)) as size FROM system.parts WHERE database='system' AND table IN ($TABLE_LIST_SQL) AND active=1 GROUP BY table ORDER BY oldest ASC"

# 실행 및 결과 출력
QUERY_RESULT=$(oc exec -n "$NAMESPACE" "$POD_NAME" -- bash -c \
    "clickhouse-client --password \${CLICKHOUSE_ADMIN_PASSWORD} -d system -q \"$CHECK_MIN_QUERY\"" 2>&1)

if [ $? -eq 0 ]; then
    echo "$QUERY_RESULT" | column -t -s "$(printf '\t')"
    
    # 종료 파티션의 다음 월 계산
    END_YEAR=${END_PARTITION:0:4}
    END_MONTH=${END_PARTITION:4:2}
    NEXT_MONTH=$((10#$END_MONTH + 1))
    NEXT_YEAR=$END_YEAR
    if [ $NEXT_MONTH -gt 12 ]; then
        NEXT_MONTH=1
        NEXT_YEAR=$((END_YEAR + 1))
    fi
    EXPECTED_PARTITION=$(printf "%04d%02d" $NEXT_YEAR $NEXT_MONTH)
    
    echo "--------------------------------------------------------"
    echo "✅ 위 목록의 'oldest' 값이 $EXPECTED_PARTITION 이상이면 성공입니다."
    echo "   (삭제 범위: $START_PARTITION ~ $END_PARTITION)"
    echo "--------------------------------------------------------"
else
    echo "❌ 최종 상태 확인 쿼리 실패:"
    echo "$QUERY_RESULT"
fi

# 에러 로그 확인
if [ -f /tmp/clickhouse_drop_errors.log ]; then
    ERROR_LINE_COUNT=$(wc -l < /tmp/clickhouse_drop_errors.log)
    if [ "$ERROR_LINE_COUNT" -gt 0 ]; then
        echo ""
        echo "⚠️  경고: $ERROR_LINE_COUNT 개의 에러가 발생했습니다."
        echo "   상세 내용: /tmp/clickhouse_drop_errors.log"
    fi
fi

echo "--------------------------------------------------------"
echo "모든 작업이 완료되었습니다."
echo "--------------------------------------------------------"
