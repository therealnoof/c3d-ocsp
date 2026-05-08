# C3D + OCSP demo on F5 SSLO (inbound)

A reference build for an F5 SSLO inbound topology that uses **C3D (Client Certificate Constrained Delegation)** with **native OCSP** validation of the client certificate.

The customer pain point this targets: the C3D + OCSP path has *several* moving pieces (three CAs, OCSP delegation, AIA extension on the client cert, forging CA upload to BIG-IP), and a single missing extension or wrong path will silently fail in ways that look like generic mTLS errors. This repo scripts the entire PKI side and stands up the OCSP responder so you can rule out the cert ecosystem and focus on BIG-IP config.

## What's in scope

| Piece | Provided |
|---|---|
| Three CAs (Server, Client, Forging) | scripted |
| BIG-IP server cert (CN=c3d.app.com, SAN includes IP) | scripted |
| Backend nginx server cert | scripted |
| Win 11 client cert with AIA pointing at the OCSP responder | scripted, exported as PFX |
| Forging CA bundle for upload to BIG-IP | scripted (PEM + PFX) |
| OCSP responder (delegated, OpenSSL-based, in Docker) | scripted |
| Backend nginx (Docker) trusting the Forging CA | scripted |
| BIG-IP SSLO config | **documented, not scripted** — see `docs/BIGIP-SSLO-CONFIG.md` |
| Win 11 cert install + browser test | documented |

## Topology

```
   Win 11 client                           BIG-IP                      Backend nginx
  ┌──────────────┐  TLS + mTLS         ┌──────────────┐    TLS         ┌──────────────┐
  │ c3d.app.com  │ ──────────────────▶ │ c3d.app.com  │ ─────────────▶ │c3d.nginx.com │
  │ client cert  │                     │  10.1.10.10  │   forged cert  │ trusts       │
  │ (Client CA)  │ ◀────────────────── │  SSLO + C3D  │   from         │ Forging CA   │
  └──────────────┘                     └──────┬───────┘   Forging CA   └──────────────┘
                                              │
                                  OCSP query  │
                                              ▼
                                       ┌──────────────┐
                                       │ ocsp.demo.com│
                                       │   :2560      │
                                       │ (OpenSSL     │
                                       │  delegated   │
                                       │  responder)  │
                                       └──────────────┘
```

## Repository layout

```
c3d-ocsp/
├── README.md                  ← this file
├── pki.conf                   ← central hostnames + paths + validity windows
├── scripts/
│   ├── 00-init.sh             create out/ dirs and CA databases
│   ├── 01-create-cas.sh       three CAs + delegated OCSP responder cert
│   ├── 02-issue-bigip-cert.sh BIG-IP server cert (CN+SAN)
│   ├── 03-issue-backend-cert.sh nginx backend cert
│   ├── 04-issue-client-cert.sh Win 11 client cert with AIA → OCSP
│   ├── 05-export-pkcs12.sh    PFX bundles for Win 11 + BIG-IP
│   └── helpers/openssl.cnf    shared OpenSSL config
├── ocsp/                      OpenSSL OCSP responder in Docker
├── nginx/                     demo backend in Docker
├── docs/
│   ├── ARCHITECTURE.md        topology + cert chain in detail
│   ├── OCSP-SERVER.md         deep dive on the OCSP responder
│   ├── BIGIP-SSLO-CONFIG.md   step-by-step SSLO config (you fill in)
│   └── CLIENT-WIN11.md        Win 11 cert import + browser test
└── out/                       generated material (gitignored)
```

## Run order (the happy path)

```bash
# 1. PKI: generate everything in out/ — idempotent
bash scripts/00-init.sh
bash scripts/01-create-cas.sh
bash scripts/02-issue-bigip-cert.sh
bash scripts/03-issue-backend-cert.sh
bash scripts/04-issue-client-cert.sh
bash scripts/05-export-pkcs12.sh

# 2. Stand up OCSP responder + backend
docker compose -f ocsp/docker-compose.yml up -d
docker compose -f nginx/docker-compose.yml up -d

# 3. Configure BIG-IP — see docs/BIGIP-SSLO-CONFIG.md
#    (uploads from out/bigip/, out/forging-ca/, out/client-ca/)

# 4. Install client cert on Win 11 — see docs/CLIENT-WIN11.md
#    (out/client/<client>.pfx, password from pki.conf PFX_PASSWORD)

# 5. Open https://c3d.app.com/ from Win 11. Pick the client cert
#    when prompted. Backend logs should show the forged cert
#    coming through with the original CN preserved.
```

## What makes this different from a "regular" mTLS setup

- **Three CAs, not two.** The Forging CA is a third tree whose private key lives on BIG-IP and whose public cert lives on the backend. SSLO mints a brand-new client cert at re-encrypt time using that key.
- **OCSP delegation.** The OCSP responder doesn't sign with the Client CA's key directly — it has its own short-lived signing cert delegated by Client CA. The responder cert carries `extendedKeyUsage=OCSPSigning` and the `id-pkix-ocsp-nocheck` extension so it isn't itself OCSP-checked (avoids loops).
- **AIA extension on client certs.** The client cert carries an `authorityInfoAccess` field pointing at `http://ocsp.demo.com:2560`. BIG-IP reads this and fires the OCSP query. **Forget this one extension and OCSP just doesn't happen.**
