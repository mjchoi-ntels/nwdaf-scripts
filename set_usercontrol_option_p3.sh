#!/bin/bash

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

USAGE="사용법: $0 [4g|4G|lte|LTE|5g|5G] [prb|xgboost]
  - 4g, 4G, lte, LTE : ai_model 행의 value를 수정
  - 5g, 5G           : ai_model_5g 행의 value를 수정
  - value            : prb 또는 xgboost 만 허용"

# 1. 인자값 개수 검증 (대상, 값 총 2개 필요)
if [ $# -ne 2 ]; then
    echo -e "${RED}[오류] 인자값은 2개여야 합니다. (대상, 값)${NC}"
    echo "$USAGE"
    exit 1
fi

TARGET=$1
MODEL_VALUE=$2

# 2. 첫 번째 인자(대상)에 따라 수정할 설정 행(name)을 결정
#    4g/4G/lte/LTE -> ai_model, 5g/5G -> ai_model_5g
case "$TARGET" in
    4g|4G|lte|LTE)
        CONFIG_NAME="ai_model"
        ;;
    5g|5G)
        CONFIG_NAME="ai_model_5g"
        ;;
    *)
        echo -e "${RED}[오류] 올바르지 않은 대상 인자입니다: $TARGET${NC}"
        echo "$USAGE"
        exit 1
        ;;
esac

# 3. 두 번째 인자(값) 검증 - prb, xgboost 만 허용 (대소문자 구분 없음)
#    입력값을 소문자로 정규화하여 검증 및 저장에 사용
MODEL_VALUE=$(echo "$MODEL_VALUE" | tr '[:upper:]' '[:lower:]')

if [[ ! "$MODEL_VALUE" =~ ^(prb|xgboost)$ ]]; then
    echo -e "${RED}[오류] 올바르지 않은 값입니다: $2${NC}"
    echo "$USAGE"
    exit 1
fi

echo -e "${GREEN}[정보] '$CONFIG_NAME' 설정을 '$MODEL_VALUE'으로 설정합니다.${NC}"

# 4. 현재 로그인 사용자 확인
CURRENT_USER=$(oc whoami 2>/dev/null)

if [ -z "$CURRENT_USER" ]; then
    echo -e "${RED}[오류] OpenShift에 로그인되어 있지 않습니다.${NC}"
    exit 1
fi

echo -e "${GREEN}[정보] 현재 사용자: $CURRENT_USER${NC}"

if [ "$CURRENT_USER" != "nwdaf-admin" ]; then
    echo -e "${RED}[오류] 현재 사용자가 nwdaf-admin이 아닙니다.${NC}"
    echo "이 스크립트는 nwdaf-admin 권한으로 실행되어야 합니다."
    echo "다음 명령어로 로그인 후 다시 시도해주세요:"
    echo "  oc login -u nwdaf-admin"
    exit 1
fi

# 5. role=primary 라벨이 있는 cloudnative-pg-cluster 파드 찾기
echo -e "${GREEN}[정보] Primary PostgreSQL 파드를 찾는 중...${NC}"

# cnpg.io/instanceRole=primary 라벨로 직접 쿼리
POD_NAME=$(oc get pod -n nwdaf -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

# 라벨 셀렉터로 찾지 못했다면 기존 방식으로 시도
if [ -z "$POD_NAME" ]; then
    POD_NAME=$(oc get pod -n nwdaf --show-labels | grep cloudnative-pg-cluster | grep primary | awk '{print $1}' | head -1)
fi

if [ -z "$POD_NAME" ]; then
    echo -e "${RED}[오류] Primary PostgreSQL 파드를 찾을 수 없습니다.${NC}"
    echo "디버깅: 다음 명령어를 수동으로 실행해보세요:"
    echo "  oc get pod -n nwdaf --show-labels | grep cloudnative-pg-cluster"
    exit 1
fi

echo -e "${GREEN}[정보] Primary 파드 발견: $POD_NAME${NC}"

# 6. PostgreSQL에 접속하여 현재 설정값 확인
echo -e "${GREEN}[정보] PostgreSQL에서 현재 설정값을 확인합니다...${NC}"

CURRENT_VALUE=$(oc exec -n nwdaf "$POD_NAME" -- bash -c "psql -U postgres -d nwdaf -t -c \"SELECT value FROM t_config_common WHERE name = '$CONFIG_NAME';\"" 2>/dev/null | tr -d '[:space:]')

if [ -z "$CURRENT_VALUE" ]; then
    echo -e "${RED}[오류] 현재 설정값을 가져올 수 없습니다.${NC}"
    echo "'$CONFIG_NAME' 행이 t_config_common 테이블에 존재하지 않을 수 있습니다."
    exit 1
fi

echo -e "${GREEN}[정보] 현재 '$CONFIG_NAME' 설정값: $CURRENT_VALUE${NC}"

# 7. 현재 값과 입력 값이 동일한지 확인
if [ "$CURRENT_VALUE" == "$MODEL_VALUE" ]; then
    echo -e "${YELLOW}[알림] 이미 ${MODEL_VALUE}로 서비스되고 있습니다. 스크립트를 종료합니다.${NC}"
    echo ""
    echo "=== 현재 설정 테이블 조회 결과 ==="
    oc exec -n nwdaf "$POD_NAME" -- bash -c "psql -U postgres -d nwdaf -c \"SELECT * FROM t_config_common;\""
    exit 0
fi

# 8. 값이 다른 경우 UPDATE 수행
echo -e "${YELLOW}[작업] '$CONFIG_NAME' 값을 ${CURRENT_VALUE}에서 ${MODEL_VALUE}로 변경합니다...${NC}"

UPDATE_RESULT=$(oc exec -n nwdaf "$POD_NAME" -- bash -c "psql -U postgres -d nwdaf -c \"UPDATE t_config_common SET value = '$MODEL_VALUE' WHERE name = '$CONFIG_NAME';\"" 2>&1)

if [[ $UPDATE_RESULT == *"UPDATE 1"* ]]; then
    echo -e "${GREEN}[완료] 설정이 성공적으로 변경되었습니다.${NC}"
    echo ""
    echo "=== 변경 후 설정 테이블 조회 결과 ==="
    oc exec -n nwdaf "$POD_NAME" -- bash -c "psql -U postgres -d nwdaf -c \"SELECT * FROM t_config_common;\""
elif [[ $UPDATE_RESULT == *"UPDATE 0"* ]]; then
    echo -e "${RED}[오류] 변경 대상 행을 찾지 못했습니다.${NC}"
    echo "'$CONFIG_NAME' 행이 t_config_common 테이블에 존재하지 않습니다."
    exit 1
else
    echo -e "${RED}[오류] 설정 변경에 실패했습니다.${NC}"
    echo "$UPDATE_RESULT"
    exit 1
fi

echo -e "${GREEN}[완료] 모든 작업이 완료되었습니다.${NC}"
echo -e "${GREEN}[완료시간] $(date '+%Y-%m-%d %H:%M:%S')${NC}"
