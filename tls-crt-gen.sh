# TLS 및 CA 인증서 저장 경로
mkdir -p /tls

echo "Generating CA (Certificate Authority)..."
openssl genrsa -out /tls/RootCA.key 2048
openssl req -x509 -new -nodes -key /tls/RootCA.key -sha256 -days 365 \
-out /tls/RootCA.crt -subj "/CN=nwdaf/O=nTels"

echo "Creating OpenSSL config for SAN (Subject Alternative Name)..."
cat <<EOF > /tls/openssl.cnf
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = 192.168.15.99

[v3_req]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
IP.1 = 60.30.163.120
IP.2 = 60.30.163.117
IP.3 = 60.30.163.118
IP.4 = 60.30.163.119
IP.5 = 127.0.0.1
DNS.1 = localhost
EOF

echo "Generating API Gateway TLS certificate..."
openssl genrsa -out /tls/tls.key 2048
openssl req -new -key /tls/tls.key -out /tls/tls.csr -config /tls/openssl.cnf

echo "Signing TLS certificate with CA..."
openssl x509 -req -in /tls/tls.csr -CA /tls/RootCA.crt -CAkey /tls/RootCA.key \
-CAcreateserial -out /tls/tls.crt -days 365 -sha256 -extfile /tls/openssl.cnf -extensions v3_req

echo "TLS Certificate generated successfully!"
