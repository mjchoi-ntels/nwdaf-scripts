#!/bin/bash
export PATH=/usr/local/bin:/usr/bin:/bin
set -e

# 백업할 차트 목록
charts=(
    "clickhouse"
    "cloudnative-pg"
    "cluster"
    "external-secrets"
    "fluent-bit"
    "infra-auth"
    "infra-deploy"
    "infra-monitor"
    "infrastructure"
    "local-path-provisioner"
    "minio"
    "opensearch"
    "opensearch-dashboards"
)

repo="nwdaf"
repo_url="https://60.15.24.7:3000/api/packages/nwdaf/helm"
downloaded=()
BACKUP_DIR="/home/core/BACKUP"

mkdir -p "$BACKUP_DIR"
cd "$BACKUP_DIR"

# 헬름 저장소 등록 및 업데이트
if ! helm repo list | grep -q "^$repo"; then
  helm repo add "$repo" "$repo_url" --insecure-skip-tls-verify
fi
helm repo update

# 차트별로 pull 및 파일명 기록
for chart in "${charts[@]}"; do
  helm pull "$repo/$chart" --insecure-skip-tls-verify
  new_tgz=$(ls ${chart}-*.tgz | tail -n 1)
  downloaded+=("$new_tgz")
done

# 백업 파일명
backup_file="helm_backup_$(date +%Y%m%d).tar"

# tgz 파일만 tar로 묶기
tar cvf "$backup_file" "${downloaded[@]}"

# tgz 파일만 삭제
for f in "${downloaded[@]}"; do
  rm -f "$f"
done

# /home/bkms로 파일 이동 및 소유자 변경
TARGET_DIR="/home/bkms/BACKUP"
sudo mv "$backup_file" "$TARGET_DIR/"
sudo chown bkms:bkms "$TARGET_DIR/$backup_file"

# 2일 이상 경과된 tar 파일 삭제 (bkms 디렉터리에서)
sudo find "$TARGET_DIR" -type f -name "helm_backup_*.tar" -mtime +7 -exec rm -f {} \;

echo "백업 완료: $TARGET_DIR/$backup_file"