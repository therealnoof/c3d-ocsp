#!/usr/bin/env bash
# =============================================================
#  01-create-cas.sh — three CAs + a delegated OCSP responder cert
# =============================================================
#  Generates:
#    out/server-ca/ca.{key,crt}      — issues BIG-IP server cert
#    out/client-ca/ca.{key,crt}      — issues client + OCSP certs
#    out/forging-ca/ca.{key,crt}     — BIG-IP forges from this
#    out/ocsp/ocsp.{key,crt}         — OCSP responder, delegated by Client CA
#
#  Each CA's public cert is also copied into a "trust bundle"
#  flavor (PEM-encoded) so you can hand the right one to BIG-IP
#  trust stores or to nginx without renaming.
#
#  Idempotent — re-running skips what already exists. Delete the
#  output dirs to start over.
# =============================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/pki.conf"

OPENSSL_CNF="$HERE/helpers/openssl.cnf"

# --- helpers ----------------------------------------------------
make_ca() {
  local label="$1" dir="$2" cn="$3"
  if [[ -f "$dir/ca.crt" && -f "$dir/ca.key" ]]; then
    echo "[ca]   $label already present, skipping."
    return
  fi
  echo "[ca]   creating $label  ($cn)"
  mkdir -p "$dir/newcerts"

  openssl genrsa -out "$dir/ca.key" "$CA_KEY_BITS" 2>/dev/null
  chmod 600 "$dir/ca.key"

  CA_DIR="$dir" EE_DAYS="$CA_DAYS" \
  openssl req -new -x509 -sha256 \
    -days "$CA_DAYS" \
    -key "$dir/ca.key" \
    -out "$dir/ca.crt" \
    -extensions v3_ca \
    -config "$OPENSSL_CNF" \
    -subj "/C=$SUBJ_C/ST=$SUBJ_ST/L=$SUBJ_L/O=$SUBJ_O/OU=$SUBJ_OU/CN=$cn"

  # Convenience copies named after the role
  cp "$dir/ca.crt" "$dir/$(basename "$dir").crt"
}

# --- 1. Server CA ----------------------------------------------
make_ca "Server CA"  "$SERVER_CA_DIR"  "C3D Demo Server CA"

# --- 2. Client CA ----------------------------------------------
make_ca "Client CA"  "$CLIENT_CA_DIR"  "C3D Demo Client CA"

# --- 3. Forging CA ---------------------------------------------
make_ca "Forging CA" "$FORGING_CA_DIR" "C3D Demo Forging CA"

# --- 4. OCSP responder cert (delegated by Client CA) -----------
# This is what signs OCSP responses for client certs that the
# Client CA issued. It is itself NOT OCSP-checked thanks to the
# id-pkix-ocsp-nocheck extension declared in openssl.cnf.

if [[ -f "$OCSP_DIR/ocsp.crt" && -f "$OCSP_DIR/ocsp.key" ]]; then
  echo "[ocsp] OCSP responder cert already present, skipping."
else
  echo "[ocsp] issuing OCSP responder cert (delegated by Client CA)"
  mkdir -p "$OCSP_DIR"

  openssl genrsa -out "$OCSP_DIR/ocsp.key" "$EE_KEY_BITS" 2>/dev/null
  chmod 600 "$OCSP_DIR/ocsp.key"

  openssl req -new \
    -key "$OCSP_DIR/ocsp.key" \
    -out "$OCSP_DIR/ocsp.csr" \
    -subj "/C=$SUBJ_C/ST=$SUBJ_ST/L=$SUBJ_L/O=$SUBJ_O/OU=$SUBJ_OU/CN=$OCSP_FQDN" \
    -config "$OPENSSL_CNF"

  CA_DIR="$CLIENT_CA_DIR" EE_DAYS="$OCSP_RESP_DAYS" \
  openssl ca -batch -notext \
    -config "$OPENSSL_CNF" \
    -extensions v3_ocsp_responder \
    -days "$OCSP_RESP_DAYS" \
    -in "$OCSP_DIR/ocsp.csr" \
    -out "$OCSP_DIR/ocsp.crt"

  rm -f "$OCSP_DIR/ocsp.csr"
fi

# Build a chain for the OCSP responder (responder cert + Client CA)
cat "$OCSP_DIR/ocsp.crt" "$CLIENT_CA_DIR/ca.crt" > "$OCSP_DIR/ocsp-chain.crt"

echo
echo "──────────────────────────────────────────────────"
echo "CAs ready:"
ls -1 "$SERVER_CA_DIR/ca.crt" "$CLIENT_CA_DIR/ca.crt" "$FORGING_CA_DIR/ca.crt" "$OCSP_DIR/ocsp.crt"
echo "──────────────────────────────────────────────────"
