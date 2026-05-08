# BIG-IP SSLO configuration (TMOS 21.x) — skeleton

> **You'll know most of this already** — this doc exists so the customer has a single reference that ties the cert files this lab produces to specific BIG-IP fields and screens. Fill in screen names / GUI paths from your own SSLO version-specific deployment as needed.

## Pre-flight

Before you touch SSLO, the host needs:

| Item | What | Where it came from |
|---|---|---|
| Server CA cert | trust store | `out/server-ca/ca.crt` |
| BIG-IP server cert + key | client SSL profile | `out/bigip/bigip.crt`, `out/bigip/bigip.key` (or `bigip-fullchain.crt` for chained import) |
| Client CA cert | client-cert-validation trust | `out/client-ca/ca.crt` |
| Forging CA cert + key | C3D forging config | `out/forging-ca/ca.crt`, `out/forging-ca/ca.key` (or `out/forging-ca/forging-ca.pfx`) |

DNS / network requirements:
- BIG-IP self-IP / route can reach `ocsp.demo.com:2560`.
- BIG-IP can reach `c3d.nginx.com:443` (the backend).
- Win 11 client resolves `c3d.app.com` to `10.1.10.10`.

## Quick TMSH cert install (recommended)

If you'd rather skip the GUI, this is the copy-paste path. From the lab host (where you ran the cert scripts):

```bash
# 1. Bundle every BIG-IP-bound file into a single tarball
bash scripts/06-package-for-bigip.sh

# 2. Copy it to the BIG-IP
scp out/c3d-ocsp-bigip.tar.gz root@<bigip-mgmt-ip>:/var/tmp/

# 3. SSH to the BIG-IP and unpack
ssh root@<bigip-mgmt-ip>
cd /var/tmp && tar xzf c3d-ocsp-bigip.tar.gz
```

Then on the BIG-IP, drop into `tmsh` and run this block (idempotent — re-running replaces):

```tmsh
# BIG-IP virtual server cert + key
install /sys crypto cert c3d_bigip_server from-local-file /var/tmp/bigip/bigip.crt
install /sys crypto key  c3d_bigip_server from-local-file /var/tmp/bigip/bigip.key

# Server CA — trust for backend re-encrypt validation
install /sys crypto cert c3d_server_ca from-local-file /var/tmp/server-ca/ca.crt

# Client CA — trust for client cert verification (and OCSP responder chain)
install /sys crypto cert c3d_client_ca from-local-file /var/tmp/client-ca/ca.crt

# Forging CA cert + key — what BIG-IP uses to mint forged client certs at re-encrypt
install /sys crypto cert c3d_forging_ca from-local-file /var/tmp/forging-ca/ca.crt
install /sys crypto key  c3d_forging_ca from-local-file /var/tmp/forging-ca/ca.key

# Persist
save /sys config

# Sanity check
list /sys crypto cert c3d_bigip_server c3d_server_ca c3d_client_ca c3d_forging_ca
list /sys crypto key  c3d_bigip_server c3d_forging_ca
```

> If your environment prefers PFX over PEM for the forging cert+key, swap the two forging-CA lines for one PKCS#12 import:
>
> ```tmsh
> install /sys crypto pkcs12 c3d_forging_ca from-local-file /var/tmp/forging-ca/forging-ca.pfx
> ```
>
> Password is whatever `PFX_PASSWORD` was set to when you ran `scripts/05-export-pkcs12.sh` (default `changeme`).

After the tmsh block, **delete the staged files** so the private keys aren't sitting in `/var/tmp`:

```bash
rm -rf /var/tmp/bigip /var/tmp/server-ca /var/tmp/client-ca /var/tmp/forging-ca /var/tmp/c3d-ocsp-bigip.tar.gz
```

## Upload the certs (GUI alternative)

If you'd rather use the GUI instead of TMSH:

System ▸ Certificate Management ▸ Traffic Certificate Management ▸ SSL Certificate List

For each of the four imports, give them recognizable names so SSLO config below can reference them cleanly:

| Source file | Suggested name on BIG-IP | Purpose |
|---|---|---|
| `out/server-ca/ca.crt` | `c3d_server_ca` | Trust for backend re-encrypt validation |
| `out/bigip/bigip.crt` + `.key` | `c3d_bigip_server` | Client SSL profile cert+key |
| `out/client-ca/ca.crt` | `c3d_client_ca` | Trust store for client cert verification |
| `out/forging-ca/forging-ca.pfx` (with password from `pki.conf` `PFX_PASSWORD`) | `c3d_forging_ca` | C3D forging cert+key |

PEM equivalents are at `out/forging-ca/ca.crt` + `ca.key` if PFX import is unavailable.

## SSL profiles

### Client SSL profile (Win 11 → BIG-IP)

- **Certificate**: `c3d_bigip_server` (cert) and matching key
- **Chain**: `c3d_server_ca` if you want chain on the wire
- **Client Certificate**: `request` *(C3D needs the original client cert in hand)*
- **Trusted Certificate Authorities**: `c3d_client_ca`
- **Advertised Certificate Authorities**: `c3d_client_ca`
- **Frequency**: `once`
- **OCSP**: configure an OCSP profile (next section) and attach it; or rely on AIA-driven OCSP if your version supports it

### Server SSL profile (BIG-IP → backend nginx)

- **Trusted Certificate Authorities**: `c3d_server_ca` (so BIG-IP validates `c3d.nginx.com`'s cert)
- **Server Name**: `c3d.nginx.com` (SNI)

## OCSP

System ▸ Certificate Management ▸ OCSP Stapling Profile (or the OCSP Authentication Profile, depending on the validation point):

- **Cache size / timeout**: defaults are fine for the demo
- **OCSP responder URL**: blank — the AIA on the client cert is authoritative
- **Trusted CA**: `c3d_client_ca` (so the responder cert chains correctly)

> If your version supports it, **let AIA drive the OCSP URL** rather than hardcoding it. The AIA on `out/client/test-user.crt` is `http://ocsp.demo.com:2560` — confirm with `openssl x509 -in out/client/test-user.crt -noout -ext authorityInfoAccess`.

Attach the OCSP profile to the Client SSL profile / SSLO topology so it fires on each client cert validation.

## SSLO inbound topology

Create an inbound L3 topology in the SSLO guided config:

- **VIP**: Address `10.1.10.10`, Port `443`
- **Client SSL Profile**: the one you defined above
- **Server SSL Profile**: the one you defined above
- **Pool**: single member, `c3d.nginx.com:443` (or its IP if no DNS)

In the topology config, enable:

- **Client certificate authentication**: required
- **Client cert validation**: with OCSP (the profile above)
- **C3D (Client Certificate Constrained Delegation)** under "SSL Inspection" / "C3D" depending on version: enable, choose `c3d_forging_ca` for the forging cert+key

## Validation walkthrough

1. From a host that resolves `c3d.app.com` to the VIP, `curl -kv https://c3d.app.com/` (without a client cert) should fail at the client-cert request stage — that proves the client SSL profile is asking for one.
2. With a real client cert (`out/client/test-user.crt` + `.key`):
   ```
   curl --cert out/client/test-user.crt --key out/client/test-user.key \
     --cacert out/server-ca/ca.crt \
     https://c3d.app.com/
   ```
   You should see the nginx response page, with `Forged client subject:` containing `CN=test-user`.
3. On the OCSP responder, `docker compose -f ocsp/docker-compose.yml logs -f` should show one OCSP request per validation.
4. On nginx, `docker compose -f nginx/docker-compose.yml logs -f` should log `client_cn=[CN=test-user]` even though the client never directly talked to nginx.

If any step fails, [`OCSP-SERVER.md`](./OCSP-SERVER.md) has the OCSP-side troubleshooting checklist; the rest is standard SSLO debugging via tcpdump on the relevant interface.

## Common stumbles (fill in as you encounter them)

| Symptom | Likely cause |
|---|---|
| TLS to BIG-IP succeeds without prompting for cert | Client SSL profile's "Client Certificate" is `ignore` instead of `request` / `require` |
| Client cert prompted but rejected | Client CA not in trust store, or wrong CA in `Trusted Certificate Authorities` |
| Cert accepted but no OCSP traffic on the wire | AIA missing on cert, OR OCSP profile not attached, OR BIG-IP can't resolve/reach the responder |
| OCSP request seen, response signed by wrong CA | Responder cert wasn't issued by Client CA (recreate via `scripts/01-create-cas.sh`) |
| Backend gets connection but says "no client cert" | C3D not enabled, OR `ssl_verify_client` off on nginx, OR Forging CA not loaded into nginx trust |
| Backend rejects the forged cert | nginx's `ssl_client_certificate` doesn't include Forging CA |
| Forged cert lands but with wrong subject | C3D attribute mapping in SSLO doesn't include CN — check the C3D config |
