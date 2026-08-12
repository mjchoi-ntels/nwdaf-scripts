#!/bin/bash

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 1. 인자값 검증
if [ $# -eq 0 ]; then
    echo -e "${RED}[오류] 인자값이 입력되지 않았습니다.${NC}"
    echo "사용법: $0 [prb|lstm|gru]"
    exit 1
elif [ $# -gt 1 ]; then
    echo -e "${RED}[오류] 인자값이 2개 이상 입력되었습니다.${NC}"
    echo "사용법: $0 [prb|lstm|gru]"
    exit 1
fi

MODEL_TYPE=$1

# prb, lstm, gru 중 하나인지 확인
if [[ ! "$MODEL_TYPE" =~ ^(prb|lstm|gru)$ ]]; then
    echo -e "${RED}[오류] 올바르지 않은 인자값입니다: $MODEL_TYPE${NC}"
    echo "사용법: $0 [prb|lstm|gru]"
    exit 1
fi

echo -e "${GREEN}[정보] AI 모델을 '$MODEL_TYPE'으로 설정합니다.${NC}"

# 3. 현재 로그인 사용자 확인
CURRENT_USER=$(oc whoami 2>/dev/null)

if [ $? -ne 0 ]; then
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

# 4. role=primary 라벨이 있는 cloudnative-pg-cluster 파드 찾기
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

CURRENT_VALUE=$(oc exec -n nwdaf "$POD_NAME" -- bash -c "psql -U postgres -d nwdaf -t -c \"SELECT value FROM t_config_common WHERE name = 'ai_model';\"" 2>/dev/null | tr -d '[:space:]')

if [ -z "$CURRENT_VALUE" ]; then
    echo -e "${RED}[오류] 현재 설정값을 가져올 수 없습니다.${NC}"
    exit 1
fi

echo -e "${GREEN}[정보] 현재 AI 모델 설정값: $CURRENT_VALUE${NC}"

# 7. 현재 값과 입력 인자가 동일한지 확인
if [ "$CURRENT_VALUE" == "$MODEL_TYPE" ]; then
    echo -e "${YELLOW}[알림] 이미 ${MODEL_TYPE}로 서비스되고 있습니다. 스크립트를 종료합니다.${NC}"
    echo ""
    echo "=== 현재 설정 테이블 조회 결과 ==="
    oc exec -n nwdaf "$POD_NAME" -- bash -c "psql -U postgres -d nwdaf -c \"SELECT * FROM t_config_common;\""
    exit 0
fi

# 8. 값이 다른 경우 UPDATE 수행
echo -e "${YELLOW}[작업] AI 모델을 ${CURRENT_VALUE}에서 ${MODEL_TYPE}로 변경합니다...${NC}"

UPDATE_RESULT=$(oc exec -n nwdaf "$POD_NAME" -- bash -c "psql -U postgres -d nwdaf -c \"UPDATE t_config_common SET value = '$MODEL_TYPE' WHERE name = 'ai_model';\"" 2>&1)

if [[ $UPDATE_RESULT == *"UPDATE 1"* ]]; then
    echo -e "${GREEN}[완료] AI 모델이 성공적으로 변경되었습니다.${NC}"
    echo ""
    echo "=== 변경 후 설정 테이블 조회 결과 ==="
    oc exec -n nwdaf "$POD_NAME" -- bash -c "psql -U postgres -d nwdaf -c \"SELECT * FROM t_config_common;\""
else
    echo -e "${RED}[오류] AI 모델 변경에 실패했습니다.${NC}"
    echo "$UPDATE_RESULT"
    exit 1
fi

echo -e "${GREEN}[완료] 모든 작업이 완료되었습니다.${NC}"
echo -e "${GREEN}[완료시간] $(date '+%Y-%m-%d %H:%M:%S')${NC}"
