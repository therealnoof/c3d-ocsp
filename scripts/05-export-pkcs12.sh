#!/usr/bin/env bash
# =============================================================
#  05-export-pkcs12.sh — PFX bundles for Win 11 + BIG-IP
# =============================================================
#  Win 11's "Personal Information Exchange (.pfx)" import wants
#  PKCS#12 bundles. BIG-IP TMOS 21 accepts both PEM and PKCS#12;
#  PFX is convenient for moving the Forging CA's private key
#  onto the unit in one go.
#
#  Outputs:
#    out/client/<CN>.pfx          — Win 11 user's identity bundle
#    out/forging-ca/forging-ca.pfx — for BIG-IP forging cert+key import
#
#  Password for both is PFX_PASSWORD from pki.conf (default
#  'changeme'). Override the env var before running for anything
#  beyond a demo.
# =============================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/pki.conf"

# --- Win 11 client ----------------------------------------------
CLIENT_PFX="$CLIENT_DIR/${CLIENT_CN}.pfx"
echo "[pfx] client → $CLIENT_PFX"
openssl pkcs12 -export \
  -in     "$CLIENT_DIR/${CLIENT_CN}.crt" \
  -inkey  "$CLIENT_DIR/${CLIENT_CN}.key" \
  -certfile "$CLIENT_CA_DIR/ca.crt" \
  -name   "C3D Demo — ${CLIENT_CN}" \
  -passout "pass:${PFX_PASSWORD}" \
  -out    "$CLIENT_PFX"

# --- BIG-IP forging CA -----------------------------------------
FORGE_PFX="$FORGING_CA_DIR/forging-ca.pfx"
echo "[pfx] forging CA → $FORGE_PFX"
openssl pkcs12 -export \
  -in     "$FORGING_CA_DIR/ca.crt" \
  -inkey  "$FORGING_CA_DIR/ca.key" \
  -name   "C3D Demo — Forging CA" \
  -passout "pass:${PFX_PASSWORD}" \
  -out    "$FORGE_PFX"

echo
echo "──────────────────────────────────────────────────"
echo "PFX bundles ready (password: $PFX_PASSWORD)"
echo "  Win 11:  $CLIENT_PFX"
echo "  BIG-IP:  $FORGE_PFX"
echo
echo "PEM equivalents (if BIG-IP import wants PEM):"
echo "  $FORGING_CA_DIR/ca.key"
echo "  $FORGING_CA_DIR/ca.crt"
echo "──────────────────────────────────────────────────"
