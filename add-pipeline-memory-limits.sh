#!/usr/bin/env bash

set -euo pipefail

########################################
# Usage
########################################
usage() {
    echo "Usage:"
    echo "  $0 <pipeline_id> <version_id> <memory limit Gi>"
    echo
    echo "Example:"
    echo "  $0 550e8400-e29b-41d4-a716-446655440000 123e4567-e89b-12d3-a456-426614174000 1024"
    exit 1
}

########################################
# Validation functions
########################################

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $1"
        exit 1
    }
}

is_uuid() {
    local uuid="$1"
    [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

is_memory() {
    local mem="$1"
    [[ "$mem" =~ ^[0-9]+[mMgG]$ ]]
}

normalize_memory() {
    local mem="$1"

    local value=${mem::-1}
    local unit=${mem: -1}

    case "$unit" in
        m|M)
            echo "${value}Mi"
            ;;
        g|G)
            echo "${value}Gi"
            ;;
        *)
            return 1
            ;;
    esac
}

########################################
##
########################################

wait_for_port() {
    local host="$1"
    local port="$2"
    local retry=30

    for ((i=0; i<retry; i++)); do
        if nc -z "$host" "$port" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done

    echo "ERROR: port-forward not ready"
    return 1
}

########################################
# Argument check
########################################

require_cmd curl
require_cmd jq
require_cmd sed

if command -v oc >/dev/null 2>&1; then
    KUBE_CMD="oc"
elif command -v kubectl >/dev/null 2>&1; then
    KUBE_CMD="kubectl"
else
    echo "ERROR: neither oc nor kubectl found"
    exit 1
fi

if [[ $# -ne 3 ]]; then
    usage
fi

PIPELINE_ID="$1"
VERSION_ID="$2"
MEMORY="$3"

if ! is_uuid "$PIPELINE_ID"; then
    echo "ERROR: invalid UUID1: $UUID1"
    exit 1
fi

if ! is_uuid "$VERSION_ID"; then
    echo "ERROR: invalid UUID2: $UUID2"
    exit 1
fi

if ! is_memory "$MEMORY"; then
    echo "ERROR: memory must be in format <number>[m|g], e.g. 512m, 2g"
    exit 1
fi

MEMORY="$(normalize_memory "$MEMORY")"

########################################
# Main
########################################

TOKEN=$($KUBE_CMD create token default-editor -n nwdaf --audience=pipelines.kubeflow.org --duration=10h)

$KUBE_CMD -n kubeflow port-forward svc/ml-pipeline 8888:8888 &>/dev/null &
PORT_FORWARD_PID=$!
trap "kill $PORT_FORWARD_PID" EXIT

wait_for_port 127.0.0.1 8888

RESULT=$(curl -s http://127.0.0.1:8888/apis/v2beta1/pipelines/${PIPELINE_ID}/versions/${VERSION_ID})

VERSION_NAME=$(echo "${RESULT}" | jq -r '.display_name')
PIPELINE_SPEC=$(echo "${RESULT}" | jq '.pipeline_spec' | sed -e 's/"resources": {}/"resources": {"limits": {"cpu": "1", "memory": "'${MEMORY}'"}, "requests": {"cpu": "1", "memory": "'${MEMORY}'"}}/g' | jq --indent 0)

printf "%s" "$PIPELINE_SPEC" | curl -sf -X POST -F "uploadfile=@-;filename=kfp.json" "http://127.0.0.1:8888/apis/v2beta1/pipelines/upload_version?name=${VERSION_NAME}-limits&pipelineid=${PIPELINE_ID}" &>/dev/null

echo "Pipeline Uploaded."

