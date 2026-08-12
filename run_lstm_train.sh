#!/usr/bin/env bash
set -e

# --- 설정 (환경에 맞게 수정) ---
PIPELINE_NAME="LSTM-Training-Workflow"
NAMESPACE="nwdaf"
KFP_SERVICE_URL="http://ml-pipeline.kubeflow.svc.cluster.local:8888" # 내부 주소 또는 포트포워딩 주소
# ----------------------------

USAGE="Usage: $0 --mem <memory> --cpu <cpu_count>"
MEM="4Gi"  # 기본값
CPU="1"    # 기본값

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --mem) MEM="$2"; shift ;;
        --cpu) CPU="$2"; shift ;;
        *) echo "$USAGE"; exit 1 ;;
    esac
    shift
done

echo "[1/3] 파이프라인 정보 조회 중..."
# 1. 파이프라인 이름으로 ID 조회 (jq 필요)
# (실제 환경에서는 포트포워딩 후 localhost:8888로 접근하거나, 클러스터 내부에서 실행)
PIPELINE_ID=$(curl -s "$KFP_SERVICE_URL/apis/v2beta1/pipelines" | jq -r ".pipelines[] | select(.display_name==\"$PIPELINE_NAME\") | .pipeline_id")

# 2. 최신 버전 ID 조회
VERSION_ID=$(curl -s "$KFP_SERVICE_URL/apis/v2beta1/pipelines/$PIPELINE_ID/versions" | jq -r '.versions[0].pipeline_version_id')

echo "[2/3] 리소스($CPU CPU, $MEM MEM) 주입 및 새 버전 업로드 중..."
# 3. 개발자 스크립트 로직 (리소스 치환 및 업로드)
RESULT=$(curl -s "$KFP_SERVICE_URL/apis/v2beta1/pipelines/$PIPELINE_ID/versions/$VERSION_ID")
VERSION_NAME=$(echo "$RESULT" | jq -r '.display_name')
PIPELINE_SPEC=$(echo "$RESULT" | jq '.pipeline_spec' | sed -e "s/\"resources\": {}/\"resources\": {\"limits\": {\"cpu\": \"$CPU\", \"memory\": \"$MEM\"}, \"requests\": {\"cpu\": \"$CPU\", \"memory\": \"$MEM\"}}/g" | jq --indent 0)

NEW_VERSION_ID=$(printf "%s" "$PIPELINE_SPEC" | curl -s -X POST -F "uploadfile=@-;filename=kfp.json" "$KFP_SERVICE_URL/apis/v2beta1/pipelines/upload_version?name=${VERSION_NAME}-$(date +%s)&pipelineid=$PIPELINE_ID" | jq -r '.pipeline_version_id')

echo "[3/3] 파이프라인 실행(Run) 생성 중..."
# 4. 즉시 실행 API 호출
RUN_NAME="LSTM-Train-Run-$(date +%Y%m%d-%H%M%S)"
curl -s -X POST "$KFP_SERVICE_URL/apis/v2beta1/runs" \
    -H "Content-Type: application/json" \
    -d "{
        \"display_name\": \"$RUN_NAME\",
        \"pipeline_version_reference\": {
            \"pipeline_id\": \"$PIPELINE_ID\",
            \"pipeline_version_id\": \"$NEW_VERSION_ID\"
        },
        \"namespace\": \"$NAMESPACE\"
    }" | jq -r '.run_id'

echo "------------------------------------------"
echo "성공! LSTM 학습 파이프라인이 시작되었습니다."
echo "실행 이름: $RUN_NAME"
echo "Kubeflow UI에서 확인하세요."