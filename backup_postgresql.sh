#!/bin/bash

# 사용법: ./oc-backup-db.sh <DB명> <백업파일명.dump> [pod번호]
# 예시: ./oc-backup-db.sh mydb mydb_full_backup.dump 1

echo $PATH



export PATH=/usr/local/bin:/usr/bin:/bin
export KUBECONFIG_FILE=$(/home/core/ocp/config/auth/login/00-login.sh)

export KUBECONFIG="${KUBECONFIG_FILE}"
echo "${KUBECONFIG}"

DB_NAME=$1
BACKUP_FILE=$2
POD_IDX=${3:-1}

NAMESPACE=nwdaf
POD_NAME=cloudnative-pg-cluster-$POD_IDX
DB_USER=postgres

if [[ -z "$DB_NAME" || -z "$BACKUP_FILE" ]]; then
  echo "사용법: $0 <DB명> <백업파일명.dump> [pod번호]"
  exit 1
fi

# ID/PW 입력 프롬프트
#read -p "OpenShift 로그인 ID: " OC_ID
#read -s -p "OpenShift 로그인 PW: " OC_PW
#echo

/bin/sh /home/core/oc_login.sh

# 백업 전 row count 추출
echo "[백업 전] 테이블별 row count:"
oc exec -n $NAMESPACE $POD_NAME -- \
  psql -U $DB_USER -d $DB_NAME -Atc \
  "SELECT table_name, row_estimate FROM (
      SELECT relname AS table_name, n_live_tup AS row_estimate
      FROM pg_stat_user_tables
      ORDER BY relname
  ) AS stats;"
echo "--------------------------"

# 백업 실행
echo "[$POD_NAME]의 [$DB_NAME] 전체 DB 백업 중..."
oc exec -n $NAMESPACE $POD_NAME -- \
  pg_dump -U $DB_USER -Fc $DB_NAME > $BACKUP_FILE

sleep 1
# === 세션(KUBECONFIG) 파일 삭제 ===
if [ -n "${KUBECONFIG_FILE}" ] && [ -f "${KUBECONFIG_FILE}" ]; then
    echo "${KUBECONFIG_FILE} Delete"
    rm -f "${KUBECONFIG_FILE}"
fi

echo "백업 완료: $BACKUP_FILE"
