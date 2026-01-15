#!/bin/bash

export PATH=/usr/local/bin:/usr/bin:/bin
export KUBECONFIG=$(/home/core/ocp/config/auth/login/00-login.sh)
source /home/core/nwdaf-pkg/.env_ocpwd
echo "${KUBECONFIG}"

# OpenShift 로그인
/home/core/oc_login.sh

# Models to back up
MODELS=("lstm_model" "gru_model")
NAMESPACE="kubeflow"
LOCAL_DEST="/home/core/BACKUP"
TARGET_DIR="/home/bkms/BACKUP"
CONTAINER="minio"
DECODE_ACCESS=$(echo "$MNO_ACCESS" | base64 -d)
DECODE_SECRET=$(echo "$MNO_SECRET" | base64 -d)

# Find the first Running minio-nwdaf pod
POD=$(oc get pod -n "$NAMESPACE" | awk '/minio-nwdaf/ && /Running/ {print $1; exit}')

if [ -z "$POD" ]; then
  echo "No running minio-nwdaf pod found in namespace $NAMESPACE."
  exit 1
fi

echo "Selected MinIO pod: $POD"

# Set mc alias and create backup directory inside the pod
oc exec -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- \
  sh -c "mc alias set local http://localhost:9000 $DECODE_ACCESS $DECODE_SECRET && mkdir -p /tmp/backup"

# Copy each model from MinIO to local destination
for model in "${MODELS[@]}"; do
  echo "Backing up model: $model"
  oc exec -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- \
    sh -c "mc cp --recursive local/model-repo/$model /tmp/backup/$model"
  oc cp "$NAMESPACE/$POD:/tmp/backup/$model" "$LOCAL_DEST/$model"

  # Tar the backed up directory with the format: directory_yyyymmdd.tar
  TAR_NAME="${model}_$(date +%Y%m%d).tar"
  tar -cvf "$LOCAL_DEST/$TAR_NAME" -C "$LOCAL_DEST" "$model"

  # Remove the original directory after tarring
  rm -rf "$LOCAL_DEST/$model"

  # Move tar file to TARGET_DIR and change ownership
  sudo mv "$LOCAL_DEST/$TAR_NAME" "$TARGET_DIR/"
  sudo chown bkms:bkms "$TARGET_DIR/$TAR_NAME"
done

# Clean up backup directory inside the pod
oc exec -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- rm -rf /tmp/backup

# Delete files older than 7 days in TARGET_DIR
for model in "${MODELS[@]}"; do
  sudo find "$TARGET_DIR" -type f -name "${model}_*.tar" -mtime +7 -exec rm -f {} \;
done

echo "Backup, tar, move, chown, cleanup, and old file removal completed."

# === 세션(KUBECONFIG) 파일 삭제 ===
if [ -n "${KUBECONFIG}" ] && [ -f "${KUBECONFIG}" ]; then
    echo "${KUBECONFIG} Delete"
    rm -f "${KUBECONFIG}"
fi