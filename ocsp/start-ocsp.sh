#!/usr/bin/env bash
# =============================================================
#  start-ocsp.sh — runs `openssl ocsp` as a long-lived responder
# =============================================================
#  We bind-mount the lab's out/ tree at /pki (read-only). That
#  gives us:
#    /pki/client-ca/index.txt   the OCSP database (status of
#                               every client cert ever issued)
#    /pki/client-ca/ca.crt      the CA whose certs we answer for
#    /pki/ocsp/ocsp.key         delegated responder signing key
#    /pki/ocsp/ocsp.crt         delegated responder cert
#                               (EKU=OCSPSigning, ocsp-no-check)
#
#  index.txt is re-read on each request, so issuing a new client
#  cert (which appends to that file) is picked up live. Restart
#  the container only if you blow away and rebuild the CA.
#
#  -port 2560 listens on all interfaces inside the container by
#  default; docker-compose maps that to the host's 2560. (Older
#  OpenSSL accepted "host:port" here, but OpenSSL 3.x wants a bare
#  port number — pass "0.0.0.0:2560" and it tries to parse it as
#  octal and dies.)
#  -text logs request and response in human-readable form, which
#  is invaluable when the customer is staring at "OCSP didn't
#  fire" and trying to figure out why.
# =============================================================

set -euo pipefail

PKI=/pki
INDEX="${PKI}/client-ca/index.txt"
CA="${PKI}/client-ca/ca.crt"
RKEY="${PKI}/ocsp/ocsp.key"
RSIGNER="${PKI}/ocsp/ocsp.crt"

for f in "$INDEX" "$CA" "$RKEY" "$RSIGNER"; do
  if [[ ! -r "$f" ]]; then
    echo "[ocsp] missing or unreadable: $f" >&2
    echo "[ocsp] did you run scripts/01-create-cas.sh and 04-issue-client-cert.sh first?" >&2
    exit 1
  fi
done

echo "[ocsp] listening on :2560"
echo "[ocsp]   CA    = $CA"
echo "[ocsp]   index = $INDEX"
echo "[ocsp]   responder cert = $RSIGNER (EKU=OCSPSigning)"

# `exec` so signals (docker stop) reach the openssl process.
exec openssl ocsp \
  -port 2560 \
  -index "$INDEX" \
  -CA "$CA" \
  -rkey "$RKEY" \
  -rsigner "$RSIGNER" \
  -text
