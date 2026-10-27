#!/bin/bash
#
# check_triton_version.sh
#
# Triton 서버가 "실제로 로드한 모델(버전/상태)"과
# "적용된 날짜버전(version 파일)"을 한 번에 확인한다.
#
#   - 로드 상태  : Triton HTTP API (/v2/repository/index) -> 폴더 번호(1/2) + READY
#   - 날짜버전   : model-repo 의 <model>_model/version 파일 (예: 2026101504)
#
# Triton 은 날짜버전 개념을 모르고 폴더 번호만 알기 때문에,
# 두 정보를 합쳐서 봐야 "지금 추론에 쓰는 게 어느 날짜버전 세트인지"가 드러난다.
#
# 사용법:
#   ./check_triton_version.sh                 # 전체(xgboost, xgboost_5g, gru, lstm)
#   ./check_triton_version.sh xgboost         # 특정 모델만
#   ./check_triton_version.sh xgboost_5g
#

NAMESPACE="nwdaf"
DEPLOY="deploy/triton-server"
TRITON_HTTP="localhost:8000"
MODELS_PATH="/mnt/models"
MODEL_TYPES=("gru" "lstm" "xgboost" "xgboost_5g")

# 모델 타입 -> Triton model name (get_model_name: "<type>_model")
model_name() {
    echo "${1}_model"
}

# 인자 검증
validate_arg() {
    local arg="$1"
    for t in "${MODEL_TYPES[@]}"; do
        [ "$t" = "$arg" ] && return 0
    done
    return 1
}

# Triton 로드 상태 (repository/index) 출력
show_load_state() {
    echo "===== Triton 로드 상태 (repository/index) ====="
    local filter="$1"
    if [ -n "$filter" ]; then
        # 특정 모델만: JSON 을 보기 좋게 쪼개서 해당 model name 블록만 표시
        oc exec -n "$NAMESPACE" "$DEPLOY" -- bash -c \
            "curl -s ${TRITON_HTTP}/v2/repository/index -X POST \
             | tr '}' '\n' | grep -i '\"$(model_name "$filter")\"'" \
            || echo "(로드 상태 조회 실패)"
    else
        oc exec -n "$NAMESPACE" "$DEPLOY" -- bash -c \
            "curl -s ${TRITON_HTTP}/v2/repository/index -X POST \
             | tr '}' '\n' | grep -iE 'name|version|state'" \
            || echo "(로드 상태 조회 실패)"
    fi
}

# 적용된 날짜버전 (version 파일) 출력 - 모델 타입 하나
show_date_version() {
    local type="$1"
    local name
    name="$(model_name "$type")"
    local version
    version=$(oc exec -n "$NAMESPACE" "$DEPLOY" -- bash -c \
        "d=\$(dirname \"\$(grep -l 'name: \"${name}\"' ${MODELS_PATH}/*/config.pbtxt | head -1)\"); \
         cat \"\$d/version\" 2>/dev/null")
    printf "  %-18s %s\n" "$name" "${version:-(없음)}"
}

main() {
    local target="$1"

    echo ""
    show_load_state "$target"

    echo ""
    echo "===== 적용 날짜버전 (model-repo version 파일) ====="
    if [ -n "$target" ]; then
        show_date_version "$target"
    else
        for t in "${MODEL_TYPES[@]}"; do
            show_date_version "$t"
        done
    fi
    echo ""
}

# 진입점
if [ $# -gt 1 ]; then
    echo "Usage: $0 [model_type]"
    echo "  model_type: ${MODEL_TYPES[*]} (생략 시 전체 조회)"
    exit 1
fi

if [ $# -eq 1 ]; then
    if ! validate_arg "$1"; then
        echo "model_type must be one of: ${MODEL_TYPES[*]}"
        exit 1
    fi
fi

main "$1"
