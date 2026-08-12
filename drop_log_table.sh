#!/bin/bash

# 설정 변수
NAMESPACE="nwdaf"
POD_NAME="clickhouse-shard0-0"
DB_NAME="system"

# 대상 테이블 리스트
TABLES=("trace_log" "part_log" "processors_profile_log" "query_log" "query_views_log" "asynchronous_metric_log" "metric_log" "text_log" "error_log")

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

echo "--------------------------------------------------------"
echo "ClickHouse 파티션 삭제 작업을 시작합니다."
echo "대상 파드: $POD_NAME (Namespace: $NAMESPACE)"
echo "--------------------------------------------------------"

# 작업 루프 (연도 및 월 설정)
# 2025년: 01~12월, 2026년: 01~02월
for YEAR_CONFIG in "2025:12" "2026:02"; do
    YEAR=$(echo $YEAR_CONFIG | cut -d: -f1)
    MAX_MONTH=$(echo $YEAR_CONFIG | cut -d: -f2)

    echo "[작업 연도: $YEAR (01월 ~ ${MAX_MONTH}월)]"

    for TABLE in "${TABLES[@]}"; do
        echo -n " -> 테이블 $TABLE 처리 중: "
        
        ERROR_COUNT=0
        SUCCESS_COUNT=0
        
        for MONTH_VAL in $(seq -w 1 $MAX_MONTH); do
            PARTITION="${YEAR}${MONTH_VAL}"
            
            # oc exec를 통해 파드 내부에서 clickhouse-client 실행
            RESULT=$(oc exec -n "$NAMESPACE" "$POD_NAME" -- bash -c \
                "clickhouse-client --password \${CLICKHOUSE_ADMIN_PASSWORD} -d $DB_NAME -q \"ALTER TABLE $TABLE ON CLUSTER default DROP PARTITION '$PARTITION'\"" 2>&1)
            
            if [ $? -eq 0 ]; then
                echo -n "${MONTH_VAL} "
                ((SUCCESS_COUNT++))
            else
                # 파티션이 이미 없는 경우는 무시
                if echo "$RESULT" | grep -q "NO_SUCH_DATA_PART\|UNKNOWN_TABLE"; then
                    echo -n "- "
                else
                    echo -n "(x) "
                    ((ERROR_COUNT++))
                    # 중요한 에러는 로그에 기록
                    echo "[ERROR] $TABLE:$PARTITION - $RESULT" >> /tmp/clickhouse_drop_errors.log
                fi
            fi
        done
        echo "| 완료 (성공: $SUCCESS_COUNT, 에러: $ERROR_COUNT)"
    done
    echo ""
done

sleep 2

echo "--------------------------------------------------------"
echo "[최종 상태 보고] 각 테이블별 가장 오래된 데이터 확인"
echo "--------------------------------------------------------"

# 확인 대상 테이블 리스트 (SQL 용)
TABLE_LIST_SQL="'trace_log','part_log','processors_profile_log','query_log','query_views_log','asynchronous_metric_log','metric_log','text_log','error_log'"

# 테이블별 최소 파티션 및 용량 확인 쿼리
CHECK_MIN_QUERY="SELECT table, min(partition) as oldest, formatReadableSize(sum(bytes_on_disk)) as size FROM system.parts WHERE database='system' AND table IN ($TABLE_LIST_SQL) AND active=1 GROUP BY table ORDER BY oldest ASC"

# 실행 및 결과 출력
QUERY_RESULT=$(oc exec -n "$NAMESPACE" "$POD_NAME" -- bash -c \
    "clickhouse-client --password \${CLICKHOUSE_ADMIN_PASSWORD} -d system -q \"$CHECK_MIN_QUERY\"" 2>&1)

if [ $? -eq 0 ]; then
    echo "$QUERY_RESULT" | column -t -s $'\t' # 탭 구분을 컬럼 형태로 예쁘게 정렬
    
    echo "--------------------------------------------------------"
    echo "✅ 위 목록의 'oldest' 값이 202603 이상이면 성공입니다."
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