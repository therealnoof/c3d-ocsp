#!/usr/bin/env bash
# =============================================================
#  04-issue-client-cert.sh — Win 11 client cert with AIA → OCSP
# =============================================================
#  This is the cert the Win 11 user presents during mTLS to the
#  BIG-IP. Two important extensions baked in by openssl.cnf:
#    - extendedKeyUsage = clientAuth
#    - authorityInfoAccess = OCSP;URI:http://ocsp.demo.com:2560
#  The AIA is what tells BIG-IP where to send the OCSP request.
#  Forget it and OCSP just doesn't happen.
#
#  Subject Alternative Name carries email + UPN so Windows /
#  AD can correlate the cert to a user identity if you wire
#  that path later.
# =============================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/pki.conf"

OPENSSL_CNF="$HERE/helpers/openssl.cnf"

mkdir -p "$CLIENT_DIR"

CRT="$CLIENT_DIR/${CLIENT_CN}.crt"
KEY="$CLIENT_DIR/${CLIENT_CN}.key"

if [[ -f "$CRT" ]]; then
  echo "[client] cert already present at $CRT — delete to reissue."
  exit 0
fi

echo "[client] generating key for ${CLIENT_CN}"
openssl genrsa -out "$KEY" "$EE_KEY_BITS" 2>/dev/null
chmod 600 "$KEY"

echo "[client] generating CSR"
openssl req -new \
  -key "$KEY" \
  -out "$CLIENT_DIR/${CLIENT_CN}.csr" \
  -subj "/C=$SUBJ_C/ST=$SUBJ_ST/L=$SUBJ_L/O=$SUBJ_O/OU=$SUBJ_OU/CN=$CLIENT_CN" \
  -config "$OPENSSL_CNF"

echo "[client] signing with Client CA"
# SAN carries email + UPN. The 1.3.6.1.4.1.311.20.2.3 OID is the
# Microsoft "User Principal Name" SAN type — needed if you ever
# want AD to map this cert to a user. Cosmetic for the demo.
export CLIENT_SAN="email:${CLIENT_EMAIL},otherName:1.3.6.1.4.1.311.20.2.3;UTF8:${CLIENT_UPN}"
export OCSP_URL

CA_DIR="$CLIENT_CA_DIR" EE_DAYS="$EE_DAYS" \
openssl ca -batch -notext \
  -config "$OPENSSL_CNF" \
  -extensions v3_client \
  -days "$EE_DAYS" \
  -in "$CLIENT_DIR/${CLIENT_CN}.csr" \
  -out "$CRT"

cat "$CRT" "$CLIENT_CA_DIR/ca.crt" > "$CLIENT_DIR/${CLIENT_CN}-fullchain.crt"
rm -f "$CLIENT_DIR/${CLIENT_CN}.csr"

echo
echo "[client] issued:"
openssl x509 -in "$CRT" -noout -subject -issuer -ext subjectAltName -ext authorityInfoAccess | sed 's/^/   /'
echo "[client] AIA points at: $OCSP_URL  (BIG-IP must be able to reach this)"
