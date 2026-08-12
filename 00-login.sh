#!/bin/bash

# local_path는 성수와 분당TB가 상이하므로 각자 환경에 맞게 수정 필요
local_path="/home/nwdaf/workdir/bastion_install_ntels_nwdaf"
source ${local_path}/processing_var.txt

api_server_name="api.${cluster_name}.${base_domain}:6443"
api_cluster_name=`echo ${api_server_name} | sed 's/\./\-/g'`

login_dir="/home/nwdaf/ocp_ntels_nwdaf/config/auth/login"

if [ ! -d "${login_dir}/kubeconfig_backup" ]; then
        mkdir ${login_dir}/kubeconfig_backup
fi

#find "${login_dir}" -type f -daystart -ctime +2 -name "config*" -exec rm {} \;
find "${login_dir}" -maxdepth 1 -type f -mtime +2 -name "config*" -exec mv {} ${login_dir}/kubeconfig_backup \;

cnt=0
max_attempts=100  # Maximum number of attempts to prevent infinite loops
while [ ${cnt} -lt ${max_attempts} ];
do
       cnt=$((cnt+1))
       if [ ! -e "${login_dir}/config${cnt}" ]; then
               touch ${login_dir}/config${cnt}
               KUBECONFIG="${login_dir}/config${cnt}"
               cat << EOF > ${login_dir}/config${cnt}
apiVersion: v1
clusters:
- cluster:
    insecure-skip-tls-verify: true
    server: https://${api_server_name}
  name: ${api_cluster_name}
kind: Config
preferences: {}
contexts:
- context:
    cluster: ${api_cluster_name}
    namespace: default
    user: viewer/${api_cluster_name}
  name: default/${api_cluster_name}/viewer
current-context: default/${api_cluster_name}/viewer
kind: Config
preferences: {}
users: []
EOF
               chmod go-r ${KUBECONFIG}
               export KUBECONFIG=${KUBECONFIG}
               oc whoami > /dev/null 2>&1
               if [ $? -ne 0 ]; then
                       oc login -u $(echo 'dmlld2Vy' | base64 -d) -p $(echo 'c2t0ITIzNA==' | base64 -d) > /dev/null 2>&1
                       if [ $? -eq 0 ]; then
                               echo ${KUBECONFIG}
                               sleep 0.1
                               if [ -e "${login_dir}/config${cnt}" ]; then
                                       break
                               fi
                       else
                               echo "Login failed, removing config file: ${KUBECONFIG}"
                               rm -f ${KUBECONFIG}
                       fi
               fi
       fi
done

# Check if maximum attempts exceeded
if [ ${cnt} -ge ${max_attempts} ]; then
    echo "ERROR: Exceeded maximum attempts (${max_attempts}). Login failed."
    exit 1
fi