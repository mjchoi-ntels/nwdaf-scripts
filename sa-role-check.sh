#!/bin/bash

# 인자 체크
if [ "$#" -ne 2 ]; then
  echo "사용법: $0 <ServiceAccount> <Namespace>"
  exit 1
fi

SA_NAME=$1
NAMESPACE=$2

echo "ServiceAccount: $SA_NAME"
echo "Namespace: $NAMESPACE"
echo "------------------------------------"

# 특정 네임스페이스에서 RoleBinding 확인
echo "[네임스페이스 내 RoleBinding 확인]"
oc get rolebinding -n "$NAMESPACE" -o json | jq -r --arg sa "$SA_NAME" '
  .items[] | select(.subjects[]?.kind == "ServiceAccount" and .subjects[]?.name == $sa) |
  "Role: \(.roleRef.name) (Namespace: \(.metadata.namespace))"
' || echo "네임스페이스 내 RoleBinding 없음"

echo "------------------------------------"

# 클러스터 전체에서 ClusterRoleBinding 확인
echo "[클러스터 전체에서 ClusterRoleBinding 확인]"
oc get clusterrolebinding -o json | jq -r --arg sa "$SA_NAME" '
  .items[] | select(.subjects[]?.kind == "ServiceAccount" and .subjects[]?.name == $sa) |
  "ClusterRole: \(.roleRef.name)"
' || echo "클러스터 전체에서 ClusterRoleBinding 없음"

echo "확인 완료"
