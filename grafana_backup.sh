#!/bin/bash

export PATH=/usr/local/bin:/usr/bin:/bin
export KUBECONFIG=$(/home/core/ocp/config/auth/login/00-login.sh)

source /home/core/nwdaf-pkg/.env_ocpwd

# OpenShift 로그인
oc login -u nwdaf-admin -p "$OC_PASS"

NAMESPACE="infra-monitor"
BACKUP_DIR="/home/core/BACKUP"
TARGET_DIR="/home/bkms"

mkdir -p "$BACKUP_DIR"

# Grafana 파드명 자동 획득 (첫 번째 파드)
POD=$(oc get pod -n $NAMESPACE -l app.kubernetes.io/name=grafana -o jsonpath="{.items[0].metadata.name}")

# 파드명이 없을 경우, 기본 패턴 사용
if [ -z "$POD" ]; then
  POD=$(oc get pod -n $NAMESPACE | grep grafana | awk '{print $1}' | head -n 1)
fi

if [ -z "$POD" ]; then
  echo "Grafana 파드를 찾을 수 없습니다."
  exit 1
fi

DATE=$(date +%Y%m%d)
BACKUP_FILE="$BACKUP_DIR/grafana_${DATE}.db"

# 파일 복사
oc cp $NAMESPACE/$POD:/var/lib/grafana/grafana.db "$BACKUP_FILE"

# /home/bkms로 파일 이동 및 소유자 변경
sudo mv "$BACKUP_FILE" "$TARGET_DIR/"
sudo chown bkms:bkms "$TARGET_DIR/grafana_${DATE}.db"

# 2일 이상 경과된 백업 파일 삭제 (bkms 디렉터리에서)
sudo find "$TARGET_DIR" -type f -name "grafana_*.db" -mtime +2 -exec rm -f {} \;

echo "백업 완료: $TARGET_DIR/grafana_${DATE}.db"