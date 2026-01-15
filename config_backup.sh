#!/bin/bash

export PATH=/usr/local/bin:/usr/bin:/bin
export KUBECONFIG=$(/home/core/ocp/config/auth/login/00-login.sh)
echo "${KUBECONFIG}"

# OpenShift 로그인
/home/core/oc_login.sh

NAMESPACE="nwdaf"
DATE=$(date +%Y%m%d)
BACKUP_DIR="/home/core/BACKUP"
TARGET_DIR="/home/bkms/BACKUP"
TAR_NAME="config_backup_${DATE}.tar"

mkdir -p "$BACKUP_DIR"
cd "$BACKUP_DIR"

declare -A RESOURCES
RESOURCES["configmap"]="policysender-config datagw"
RESOURCES["secret"]="datagw"
RESOURCES["networkpolicy"]="cmsweb"

BACKUP_FILES=()

for KIND in "${!RESOURCES[@]}"; do
  for NAME in ${RESOURCES[$KIND]}; do
    FILENAME="${NAMESPACE}_${NAME}_${KIND}_${DATE}.yaml"
    oc get $KIND $NAME -n $NAMESPACE -o yaml > "$FILENAME"
    BACKUP_FILES+=("$FILENAME")
    echo "백업완료: $FILENAME"
  done
done

# tar로 묶기
tar -cvf "$TAR_NAME" "${BACKUP_FILES[@]}"
echo "Tar 파일 생성 완료: $TAR_NAME"

# tar로 묶은 후 yaml 파일 삭제
for file in "${BACKUP_FILES[@]}"; do
  rm -f "$file"
done

# 생성된 tar 파일을 /home/bkms/로 이동 (sudo 필요)
sudo mv "$TAR_NAME" "$TARGET_DIR/"

# 소유자 변경 (sudo 필요)
sudo chown bkms:bkms "$TARGET_DIR/$TAR_NAME"

# 7일 이상 경과된 tar 파일만 /home/bkms/에서 삭제 (sudo 필요)
sudo find "$TARGET_DIR" -type f -name "config_backup_*.tar" -mtime +7 -exec rm -f {} \;
echo "7일 이상 경과된 백업 파일 삭제 완료"

# === 세션(KUBECONFIG) 파일 삭제 ===
if [ -n "${KUBECONFIG}" ] && [ -f "${KUBECONFIG}" ]; then
    echo "${KUBECONFIG} Delete"
    rm -f "${KUBECONFIG}"
fi