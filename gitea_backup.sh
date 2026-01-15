#!/bin/sh
DATE=$(date +%Y%m%d)
BACKUP_PATH=/home/bkms

echo "######################## BACKUP START ############################"

# gitea_backup 디렉터리 생성
mkdir -p $BACKUP_PATH/gitea_backup

# /APP/gitea 전체를 gitea_backup/gitea로 복사
cp -rp /APP/gitea $BACKUP_PATH/gitea_backup

# tar.gz 생성 (불필요한 파일/디렉터리 제외)
tar --exclude='gitea/log' \
    --exclude='gitea/tmp' \
    --exclude='gitea/custom/tmp' \
    --exclude='gitea/data/tmp' \
    -cvfz $BACKUP_PATH/gitea_backup/$(hostname)_git_${DATE}.tar.gz -C $BACKUP_PATH/gitea_backup gitea

chmod 755 $BACKUP_PATH/gitea_backup/$(hostname)_git_${DATE}.tar.gz
chown bkms:bkms $BACKUP_PATH/gitea_backup/$(hostname)_git_${DATE}.tar.gz

# 복사본 삭제
rm -rf $BACKUP_PATH/gitea_backup/gitea

# 7일 이상된 백업 파일 삭제
find "$BACKUP_PATH/gitea_backup" -type f -name "$(hostname)_git_*.tar.gz" -mtime +7 -exec rm -rf {} \;

echo "######################## BACKUP FINISH ############################"