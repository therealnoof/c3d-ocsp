#!/usr/bin/env bash
# =============================================================
#  03-issue-backend-cert.sh — backend nginx server cert
# =============================================================
#  CN = BACKEND_FQDN. Signed by Server CA. nginx serves TLS with
#  this. Note: nginx ALSO trusts the Forging CA for client cert
#  verification — that's a separate file, NOT this one.
# =============================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/pki.conf"

OPENSSL_CNF="$HERE/helpers/openssl.cnf"

mkdir -p "$BACKEND_DIR"

if [[ -f "$BACKEND_DIR/backend.crt" ]]; then
  echo "[backend] cert already present — delete to reissue."
  exit 0
fi

echo "[backend] generating key"
openssl genrsa -out "$BACKEND_DIR/backend.key" "$EE_KEY_BITS" 2>/dev/null
chmod 600 "$BACKEND_DIR/backend.key"

echo "[backend] generating CSR (CN=$BACKEND_FQDN)"
openssl req -new \
  -key "$BACKEND_DIR/backend.key" \
  -out "$BACKEND_DIR/backend.csr" \
  -subj "/C=$SUBJ_C/ST=$SUBJ_ST/L=$SUBJ_L/O=$SUBJ_O/OU=$SUBJ_OU/CN=$BACKEND_FQDN" \
  -config "$OPENSSL_CNF"

echo "[backend] signing with Server CA"
export BACKEND_SAN="DNS:${BACKEND_FQDN}"

CA_DIR="$SERVER_CA_DIR" EE_DAYS="$EE_DAYS" \
openssl ca -batch -notext \
  -config "$OPENSSL_CNF" \
  -extensions v3_backend_server \
  -days "$EE_DAYS" \
  -in "$BACKEND_DIR/backend.csr" \
  -out "$BACKEND_DIR/backend.crt"

cat "$BACKEND_DIR/backend.crt" "$SERVER_CA_DIR/ca.crt" > "$BACKEND_DIR/backend-fullchain.crt"
rm -f "$BACKEND_DIR/backend.csr"

# Convenience: nginx wants the Forging CA in its trust store.
# Copy it next to backend material so docker-compose's bind-mount
# is straightforward.
cp "$FORGING_CA_DIR/ca.crt" "$BACKEND_DIR/forging-ca.crt"

echo
echo "[backend] issued:"
openssl x509 -in "$BACKEND_DIR/backend.crt" -noout -subject -issuer -ext subjectAltName | sed 's/^/   /'
echo "[backend] nginx will trust forging CA at: $BACKEND_DIR/forging-ca.crt"
