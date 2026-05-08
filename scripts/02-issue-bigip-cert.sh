#!/usr/bin/env bash
# =============================================================
#  02-issue-bigip-cert.sh — BIG-IP server cert (CN + SANs)
# =============================================================
#  Issues the certificate the BIG-IP virtual server presents to
#  Win 11 clients. CN is BIGIP_VIP_FQDN; SANs include the FQDN
#  AND the IP, because some clients (and many test scenarios)
#  hit the IP directly.
#
#  Outputs:
#    out/bigip/bigip.key
#    out/bigip/bigip.crt
#    out/bigip/bigip-fullchain.crt   (server cert + Server CA)
# =============================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/pki.conf"

OPENSSL_CNF="$HERE/helpers/openssl.cnf"

mkdir -p "$BIGIP_DIR"

if [[ -f "$BIGIP_DIR/bigip.crt" ]]; then
  echo "[bigip] cert already present at $BIGIP_DIR/bigip.crt — delete to reissue."
  exit 0
fi

echo "[bigip] generating key"
openssl genrsa -out "$BIGIP_DIR/bigip.key" "$EE_KEY_BITS" 2>/dev/null
chmod 600 "$BIGIP_DIR/bigip.key"

echo "[bigip] generating CSR (CN=$BIGIP_VIP_FQDN)"
openssl req -new \
  -key "$BIGIP_DIR/bigip.key" \
  -out "$BIGIP_DIR/bigip.csr" \
  -subj "/C=$SUBJ_C/ST=$SUBJ_ST/L=$SUBJ_L/O=$SUBJ_O/OU=$SUBJ_OU/CN=$BIGIP_VIP_FQDN" \
  -config "$OPENSSL_CNF"

echo "[bigip] signing with Server CA"
export BIGIP_SAN="DNS:${BIGIP_VIP_FQDN},IP:${BIGIP_VIP_IP}"

CA_DIR="$SERVER_CA_DIR" EE_DAYS="$EE_DAYS" \
openssl ca -batch -notext \
  -config "$OPENSSL_CNF" \
  -extensions v3_bigip_server \
  -days "$EE_DAYS" \
  -in "$BIGIP_DIR/bigip.csr" \
  -out "$BIGIP_DIR/bigip.crt"

cat "$BIGIP_DIR/bigip.crt" "$SERVER_CA_DIR/ca.crt" > "$BIGIP_DIR/bigip-fullchain.crt"
rm -f "$BIGIP_DIR/bigip.csr"

echo
echo "[bigip] issued:"
openssl x509 -in "$BIGIP_DIR/bigip.crt" -noout -subject -issuer -ext subjectAltName | sed 's/^/   /'
