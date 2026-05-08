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

## Run order — machine by machine

This lab runs on three boxes. Each step is annotated with where it executes.

### On the Ubuntu VM (Docker host) — bring up PKI, OCSP responder, backend nginx

Prereqs: `docker`, `docker compose v2`, `openssl` (`apt install -y docker.io docker-compose-plugin openssl` on a fresh 22.04). Repo is cloneable directly:

```bash
git clone https://github.com/therealnoof/c3d-ocsp.git
cd c3d-ocsp

# 1. Generate the entire PKI tree — idempotent; outputs land in out/
bash scripts/00-init.sh
bash scripts/01-create-cas.sh
bash scripts/02-issue-bigip-cert.sh
bash scripts/03-issue-backend-cert.sh
bash scripts/04-issue-client-cert.sh
bash scripts/05-export-pkcs12.sh

# 2. Bundle the BIG-IP-bound files for the BIG-IP step below
bash scripts/06-package-for-bigip.sh
# → produces out/c3d-ocsp-bigip.tar.gz

# 3. Bring up OCSP responder and backend nginx
docker compose -f ocsp/docker-compose.yml up -d
docker compose -f nginx/docker-compose.yml up -d
docker compose -f ocsp/docker-compose.yml ps
docker compose -f nginx/docker-compose.yml ps

# 4. Local smoke test of the OCSP responder before pointing BIG-IP at it
openssl ocsp \
  -issuer  out/client-ca/ca.crt \
  -cert    out/client/test-user.crt \
  -url     http://localhost:2560 \
  -CAfile  out/client-ca/ca.crt \
  -resp_text -no_nonce
# Expect "Response verify OK" and "out/client/test-user.crt: good"
```

### On the BIG-IP — install certs and configure SSLO

Use the bundle you just produced. Full TMSH copy-paste block in [`docs/BIGIP-SSLO-CONFIG.md`](./docs/BIGIP-SSLO-CONFIG.md#quick-tmsh-cert-install-recommended):

```bash
# From the Ubuntu host, push the tarball to the BIG-IP
scp out/c3d-ocsp-bigip.tar.gz root@<bigip-mgmt-ip>:/var/tmp/

# SSH in, unpack, and run the tmsh block from BIGIP-SSLO-CONFIG.md
ssh root@<bigip-mgmt-ip>
cd /var/tmp && tar xzf c3d-ocsp-bigip.tar.gz
# … then enter tmsh and paste the install block …
```

After the tmsh block, configure the SSL profiles, OCSP profile, and SSLO inbound topology per [`docs/BIGIP-SSLO-CONFIG.md`](./docs/BIGIP-SSLO-CONFIG.md#ssl-profiles).

### On the Win 11 client — install certs, run the demo

Copy two files from the Ubuntu host to a USB stick, scp, or wherever:

- `out/server-ca/ca.crt` (rename to `c3d-server-ca.crt`)
- `out/client/test-user.pfx` (password is whatever `pki.conf` `PFX_PASSWORD` was set to — default `changeme`)

Then follow [`docs/CLIENT-WIN11.md`](./docs/CLIENT-WIN11.md): hosts-file entry for `c3d.app.com`, install the Server CA in **Trusted Root Certification Authorities (Local Machine)**, install the PFX in **Personal (Current User)**, then browse to `https://c3d.app.com/`.

You should land on a plain-text page that includes:
```
Forged client subject: CN=test-user, …
Forged cert verify:    SUCCESS
```
and the backend nginx logs should show the same `client_cn=[CN=test-user]`. Three independent observers (browser, nginx access log, OCSP responder log) confirming the same client identity through the SSLO inspection point — that's the demo.

## What makes this different from a "regular" mTLS setup

- **Three CAs, not two.** The Forging CA is a third tree whose private key lives on BIG-IP and whose public cert lives on the backend. SSLO mints a brand-new client cert at re-encrypt time using that key.
- **OCSP delegation.** The OCSP responder doesn't sign with the Client CA's key directly — it has its own short-lived signing cert delegated by Client CA. The responder cert carries `extendedKeyUsage=OCSPSigning` and the `id-pkix-ocsp-nocheck` extension so it isn't itself OCSP-checked (avoids loops).
- **AIA extension on client certs.** The client cert carries an `authorityInfoAccess` field pointing at `http://ocsp.demo.com:2560`. BIG-IP reads this and fires the OCSP query. **Forget this one extension and OCSP just doesn't happen.**
