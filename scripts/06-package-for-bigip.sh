#!/usr/bin/env bash
# =============================================================
#  06-package-for-bigip.sh
# =============================================================
#  Bundles every BIG-IP-bound file from out/ into one tar.gz so
#  you can scp a single artifact to the unit and run the tmsh
#  quick-install block from BIGIP-SSLO-CONFIG.md.
#
#  Output: out/c3d-ocsp-bigip.tar.gz containing:
#    bigip/bigip.crt, bigip.key, bigip-fullchain.crt
#    server-ca/ca.crt
#    client-ca/ca.crt
#    forging-ca/ca.crt, ca.key, forging-ca.pfx
#
#  Usage:
#    bash scripts/06-package-for-bigip.sh
#    scp out/c3d-ocsp-bigip.tar.gz root@<bigip>:/var/tmp/
#    ssh root@<bigip> "cd /var/tmp && tar xzf c3d-ocsp-bigip.tar.gz"
#
#  Then on the BIG-IP, the paths in the tmsh block below ("Quick
#  TMSH cert install" in BIGIP-SSLO-CONFIG.md) line up.
# =============================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/pki.conf"

BUNDLE="${OUT_DIR}/c3d-ocsp-bigip.tar.gz"

cd "$OUT_DIR"
tar czf "$BUNDLE" \
  bigip/bigip.crt \
  bigip/bigip.key \
  bigip/bigip-fullchain.crt \
  server-ca/ca.crt \
  client-ca/ca.crt \
  forging-ca/ca.crt \
  forging-ca/ca.key \
  forging-ca/forging-ca.pfx

echo "[bigip-pkg] wrote $BUNDLE ($(du -h "$BUNDLE" | cut -f1))"
echo "[bigip-pkg] next:  scp \"$BUNDLE\" root@<bigip>:/var/tmp/"
echo "[bigip-pkg]        ssh root@<bigip> 'cd /var/tmp && tar xzf c3d-ocsp-bigip.tar.gz'"
echo "[bigip-pkg]        then run the tmsh block from docs/BIGIP-SSLO-CONFIG.md"
