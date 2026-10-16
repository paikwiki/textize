#!/bin/zsh
# 로컬 개발용 자체 서명 코드사인 인증서를 만들어 로그인 키체인에 넣는다.
# 빌드마다 서명 해시가 바뀌는 ad-hoc 서명과 달리, 이 인증서로 서명하면
# macOS 권한(시스템 오디오 녹음)이 재빌드 후에도 유지된다.
set -euo pipefail
NAME="${1:-Textize Dev}"
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "already exists: $NAME"; exit 0
fi
TMP=$(mktemp -d)
cat > "$TMP/ext.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$NAME
[v3]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
subjectKeyIdentifier=hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/ext.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" -passout pass:dev -name "$NAME"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P dev -T /usr/bin/codesign -T /usr/bin/security
# 사용자 신뢰 설정에 코드사인 용도로 등록 (암호 입력 창이 뜰 수 있음)
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
rm -rf "$TMP"
security find-identity -v -p codesigning | grep "$NAME"
