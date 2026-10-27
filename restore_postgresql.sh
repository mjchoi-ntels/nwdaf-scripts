#!/bin/bash

# 사용법: ./restore_postgresql.sh <DB명> <백업파일명.dump> [테이블명]
#
#   - 테이블명을 지정하면: 해당 테이블만 선별 복구합니다.
#   - 테이블명을 생략하면: 전체 DB를 복구합니다. (실행 전 사용자 확인 필요)
#
#   ※ 주의: 3번째 인자는 '테이블명'입니다. (백업 스크립트의 3번째 인자인
#            'pod번호'와 다릅니다.) 복구 대상 Pod는 아래에서 Primary Pod를
#            자동으로 찾으므로 pod번호를 지정하지 않습니다.
#            백업 습관대로 숫자(예: 1)를 넣으면 '1'이라는 테이블을 선별 복구하려
#            시도하므로 주의하세요.
#
#   복구 대상 Pod는 CloudNativePG 클러스터의 Primary Pod를 자동으로 찾습니다.
#   (role=primary 라벨 기준. failover 등으로 Primary가 바뀌어도 자동 반영)
#
#   ※ 사전 조건: 실행 전에 운영자 본인 계정으로 OpenShift에 로그인되어 있어야
#              합니다. (예: oc login -u <사용자>)
#              서버 주소는 kubeconfig에 저장된 값을 재사용하므로 보통 생략합니다.
#              이 스크립트는 자동 로그인을 수행하지 않으며, 로그인 상태만
#              확인합니다. 누가 복구를 수행했는지 추적하기 위함입니다.
#
# 예시(전체 복구) : ./restore_postgresql.sh mydb mydb_full_backup.dump
# 예시(선별 복구) : ./restore_postgresql.sh mydb mydb_full_backup.dump users

echo $PATH
export PATH=/usr/local/bin:/usr/bin:/bin

DB_NAME=$1
BACKUP_FILE=$2
TABLE_NAME=$3          # 선택 인자(테이블명). 지정 시 선별 복구, 생략 시 전체 복구

NAMESPACE=nwdaf
DB_USER=postgres

if [[ -z "$DB_NAME" || -z "$BACKUP_FILE" ]]; then
  echo "사용법: $0 <DB명> <백업파일명.dump> [테이블명]"
  echo "  - 테이블명 지정 시: 해당 테이블만 선별 복구"
  echo "  - 테이블명 생략 시: 전체 DB 복구 (실행 전 확인)"
  echo "  ※ 3번째 인자는 '테이블명'입니다. (pod번호가 아님 - Primary Pod는 자동 탐색)"
  exit 1
fi

# 백업 파일 존재 확인
if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "에러: 백업 파일 '$BACKUP_FILE'을(를) 찾을 수 없습니다."
  exit 1
fi

# ---------------------------------------------------------------------------
# 로그인 상태 확인
#   - 복구는 드물고 위험한 작업이므로, 자동 로그인(평문 자격증명) 대신
#     운영자가 본인 계정으로 직접 oc login 한 상태에서 실행하도록 한다.
#   - 로그인돼 있지 않으면 안내 후 중단한다.
#   - 어떤 계정으로 수행하는지 출력해 추적성을 남긴다.
# ---------------------------------------------------------------------------
CURRENT_USER=$(oc whoami 2>/dev/null)
if [[ -z "$CURRENT_USER" ]]; then
  echo "에러: OpenShift에 로그인되어 있지 않습니다."
  echo "      복구를 실행하기 전에 본인 계정으로 먼저 로그인하세요:"
  echo "        oc login -u <사용자>"
  echo "      (서버 주소는 kubeconfig에 저장된 값을 사용합니다. 처음 접속하는"
  echo "       클러스터라면 'oc login <API서버> -u <사용자>' 형태로 주소를 지정하세요.)"
  exit 5
fi
echo "로그인 계정: $CURRENT_USER"

# ---------------------------------------------------------------------------
# Primary Pod 자동 탐색 (role=primary 라벨 기준)
# ---------------------------------------------------------------------------
POD_NAME=$(oc get pod -n $NAMESPACE -l role=primary -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -z "$POD_NAME" ]]; then
  echo "에러: namespace '$NAMESPACE'에서 Primary Pod를 찾을 수 없습니다. (라벨 role=primary)"
  echo "      현재 Pod 상태를 확인하세요: oc get pod -n $NAMESPACE -L role"
  exit 4
fi
echo "Primary Pod: $POD_NAME"

# 현재 테이블별 row count 출력 함수
print_row_counts() {
  oc exec -n $NAMESPACE $POD_NAME -- \
    psql -U $DB_USER -d $DB_NAME -Atc \
    "SELECT table_name, n_live_tup FROM information_schema.tables t JOIN pg_stat_user_tables s ON t.table_name = s.relname WHERE table_schema = 'public' ORDER BY table_name;"
}

echo "[복구 전] 테이블별 row count:"
print_row_counts
echo "--------------------------"

# ---------------------------------------------------------------------------
# 복구 모드 결정: 테이블명이 있으면 선별 복구, 없으면 전체 복구
# ---------------------------------------------------------------------------
if [[ -n "$TABLE_NAME" ]]; then
  # ---------- 선별 복구 ----------
  echo "[선별 복구] 대상 테이블: '$TABLE_NAME'"
  echo "주의: 테이블 '$TABLE_NAME'의 기존 데이터는 덮어쓰여집니다."
  read -r -p "계속 진행하시겠습니까? (y/N): " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "사용자가 취소했습니다. 복구를 중단합니다."
    exit 0
  fi

  echo "[$POD_NAME]의 [$DB_NAME] 테이블 '$TABLE_NAME' 복구 중..."
  oc cp $BACKUP_FILE $NAMESPACE/$POD_NAME:/tmp/oc_restore_db.dump
  oc exec -n $NAMESPACE $POD_NAME -- \
    pg_restore -U $DB_USER -d $DB_NAME --clean --if-exists -t "$TABLE_NAME" /tmp/oc_restore_db.dump
  RESTORE_RC=$?
  oc exec -n $NAMESPACE $POD_NAME -- rm -f /tmp/oc_restore_db.dump

else
  # ---------- 전체 복구 ----------
  # 비어있는지 확인하여 안내 메시지를 다르게 보여준다.
  ROW_SUM=$(oc exec -n $NAMESPACE $POD_NAME -- \
    psql -U $DB_USER -d $DB_NAME -Atc "SELECT SUM(n_live_tup) FROM pg_stat_user_tables;")

  if [[ "$ROW_SUM" != "0" && "$ROW_SUM" != "" ]]; then
    echo "경고: DB '$DB_NAME'가 비어있지 않습니다. (총 row 수: $ROW_SUM)"
    echo "전체 복구를 진행하면 기존 데이터가 모두 덮어쓰여집니다."
  else
    echo "DB '$DB_NAME'가 비어있습니다. 전체 복구를 진행할 수 있습니다."
  fi

  echo "[전체 복구] 대상 DB: '$DB_NAME' (Pod: $POD_NAME)"
  read -r -p "전체 복구를 진행하시겠습니까? (y/N): " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "사용자가 취소했습니다. 복구를 중단합니다."
    exit 0
  fi

  echo "[$POD_NAME]의 [$DB_NAME] 전체 DB 복구 중..."
  oc cp $BACKUP_FILE $NAMESPACE/$POD_NAME:/tmp/oc_restore_db.dump
  oc exec -n $NAMESPACE $POD_NAME -- \
    pg_restore -U $DB_USER -d $DB_NAME --clean --if-exists /tmp/oc_restore_db.dump
  RESTORE_RC=$?
  oc exec -n $NAMESPACE $POD_NAME -- rm -f /tmp/oc_restore_db.dump
fi

# 복구 결과 확인
if [[ "$RESTORE_RC" -ne 0 ]]; then
  echo "에러: pg_restore가 실패했습니다. (exit code: $RESTORE_RC)"
  exit 3
fi

# 복구 후 row count 출력
echo "[복구 후] 테이블별 row count:"
print_row_counts
echo "--------------------------"

echo "복구 완료"
