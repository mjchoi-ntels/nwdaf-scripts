#!/bin/bash

# ./curl_req.sh <method> <uri> [dataFile]

# Script 설정
#apiToken=""  # API 토큰
#destIp="60.30.163.118"                                     # 목적지 IP
#destPort="31936"                                           # 목적지 포트
grafanaSvc="infra-monitor-grafana.infra-monitor.svc"

# 인자 확인
method=$1                                            # HTTP 메서드 (필수)
uri=$2                                               # URI (필수)
dataFile=$3                                          # 데이터 파일 (선택)

# 필수 인자 확인
if [[ -z "$method" || -z "$uri" ]]; then
  echo "Usage: $0 <method> <uri> [dataFile]"
  exit 1
fi

# check if a datafile exists with the POST or PUT method
dataOption=""
if [[ "$method" == "POST" || "$method" == "PUT" ]]; then
  if [[ -n "$dataFile" ]]; then
    # 데이터 파일 검증
    if [[ ! -f "$dataFile" ]]; then
      echo "Error: Data file '$dataFile' not found."
      exit 1
    fi
    dataOption="--data @$dataFile"
  else
    # 데이터 파일이 없는 경우 사용자 입력 요청
    echo "Enter JSON data for the request body (end input with Ctrl+D):"
    inputData=$(cat)  # 멀티라인 입력 지원
    if [[ -z "$inputData" ]]; then
      echo "Error: No data provided for POST/PUT request."
      exit 1
    fi
    dataOption="--data $inputData"
  fi
fi

# CURL 명령어 실행
if [[ "$method" == "GET" || "$method" == "DELETE" ]]; then
  response=$(curl -v -s -X "$method" \
    -H "Accept: application/json" \
    -H "Authorization: Bearer $apiToken" \
    $dataOption \
    "http://$destIp:$destPort/$uri")
elif [[ "$method" == "POST" || "$method" == "PUT" ]]; then
  response=$(curl -v -s -X "$method" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $apiToken" \
    -H "X-Disable-Provenance: true" \
    $dataOption \
    "http://$destIp:$destPort/$uri")
fi

# JSON 포맷 출력
if command -v jq > /dev/null; then
  echo "Response:"
  echo "$response" | jq
else
  echo "Response (raw JSON):"
  echo "$response"
  echo "Tip: Install 'jq' for better JSON formatting."
fi