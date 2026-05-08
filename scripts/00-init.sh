#!/usr/bin/env bash
# =============================================================
#  00-init.sh — create the on-disk layout the other scripts
#  expect: per-CA database dirs, serial counters, index.txt files,
#  and an out/ tree for end-entity material.
#
#  Idempotent: running again on top of an existing tree is safe.
# =============================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/pki.conf"

mkdir -p "$OUT_DIR"

init_ca() {
  local label="$1" dir="$2"
  echo "[init] $label  ($dir)"
  mkdir -p "$dir/newcerts"
  [[ -f "$dir/index.txt" ]] || : > "$dir/index.txt"
  [[ -f "$dir/serial"    ]] || echo "1000" > "$dir/serial"
  [[ -f "$dir/crlnumber" ]] || echo "1000" > "$dir/crlnumber"
}

init_ca "Server CA"  "$SERVER_CA_DIR"
init_ca "Client CA"  "$CLIENT_CA_DIR"
init_ca "Forging CA" "$FORGING_CA_DIR"

# End-entity output directories
mkdir -p "$BIGIP_DIR" "$BACKEND_DIR" "$CLIENT_DIR" "$OCSP_DIR"

echo "[init] done. out/ tree ready under $OUT_DIR"
