#!/bin/bash

# OpenShift API URL
#API_URL="https://api.ocp21.sk.local:6443"

source /home/nwdaf/nwdaf-pkg/.env_ocpwd

# 로그인 사용자/비밀번호
DECODED_USER=$(echo "$OC_USER" | base64 -d)
DECODED_PASS=$(echo "$OC_PASS" | base64 -d)

# oc login 실행
#echo "Logging in to OpenShift cluster at $API_URL as $USERNAME"
oc login -u "$DECODED_USER" -p "$DECODED_PASS"

# 현재 프로젝트 확인
oc project

---------------------

#!/bin/bash

# 로그인 사용자/비밀번호
DECODED_USER=$(echo "bndkYWYtYWRtaW4=" | base64 -d)
DECODED_PASS=$(echo "bndkYWYxMjM0IUA=" | base64 -d)

# oc login 실행
#echo "Logging in to OpenShift cluster at $API_URL as $USERNAME"
oc login -u "$DECODED_USER" -p "$DECODED_PASS"

# 현재 프로젝트 확인
oc project

---------------------

[core@snsu-5g21b-cnfm2 nwdaf-pkg]$ cat .env_ocpwd 
OC_PASS='bndkYWYxMjM0IUA='
OC_USER='bndkYWYtYWRtaW4='
MNO_ACCESS='bWluaW8='
MNO_SECRET='bWluaW8xMjM='