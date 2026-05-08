# =============================================================
#  OCSP responder — Dockerfile
# =============================================================
#  Tiny Alpine image with OpenSSL. The actual responder process
#  is `openssl ocsp` running in daemon mode, configured by the
#  start-ocsp.sh script.
# =============================================================
FROM alpine:3.20

RUN apk add --no-cache openssl bash

EXPOSE 2560

WORKDIR /opt/ocsp
COPY start-ocsp.sh /opt/ocsp/start-ocsp.sh
RUN chmod +x /opt/ocsp/start-ocsp.sh

CMD ["/opt/ocsp/start-ocsp.sh"]
