# BIG-IP SSLO configuration (TMOS 21.x) — skeleton

> **You'll know most of this already** — this doc exists so the customer has a single reference that ties the cert files this lab produces to specific BIG-IP fields and screens. Fill in screen names / GUI paths from your own SSLO version-specific deployment as needed.
>
> F5's official C3D-with-SSLO walkthrough is at <https://techdocs.f5.com/en-us/bigip-17-1-1/ssl-orchestrator-setup/integrating_c3d_with_ssl_orchestrator.html>. The summary below tracks that flow plus the gotchas we hit standing this lab up; see the "Lessons learned" section at the bottom.

## Pre-flight

Before you touch SSLO, the host needs:

| Item | What | Where it came from |
|---|---|---|
| Server CA cert | trust store | `out/server-ca/ca.crt` |
| BIG-IP server cert + key | client SSL profile | `out/bigip/bigip.crt`, `out/bigip/bigip.key` (or `bigip-fullchain.crt` for chained import) |
| Client CA cert | client-cert-validation trust | `out/client-ca/ca.crt` |
| Forging CA cert + key | C3D forging config | `out/forging-ca/ca.crt`, `out/forging-ca/ca.key` (or `out/forging-ca/forging-ca.pfx`) |

Network requirements (TMM data plane, not the management interface):

- **TMM must have a route to the OCSP responder.** If the responder lives on a subnet that isn't directly connected to a TMM self-IP, the host-side mgmt route is *not* enough — TMM has its own routing table. Verify with `tmsh show net route` and add a static route if missing:
  ```
  tmsh create net route ocsp_subnet network 10.1.1.0/24 gw 10.1.10.1
  ```
- **TMM must be able to reach the backend** (`c3d.nginx.com:443` / its IP). Confirm via the pool monitor (`available`) plus a real `Total Requests` increment after a test, not just the monitor state.
- Win 11 client resolves `c3d.app.com` to `10.1.10.20`.

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

> **Critical**: SSL Orchestrator generates its own default client-ssl and server-ssl profiles when you deploy a topology, and **those defaults do not have C3D enabled**. You must build the two C3D-enabled profiles *first*, then in the topology / interception rule pick them as overrides. If you skip the override, your handshakes will succeed but the backend will never see a forged client cert. See the F5 doc linked at the top.

### Client SSL profile (Win 11 → BIG-IP) — TMSH

```tmsh
create ltm profile client-ssl c3d_bigip_server \
  cert-key-chain replace-all-with { c3d_bigip_server { cert c3d_bigip_server key c3d_bigip_server chain c3d_server_ca } } \
  client-cert-ca c3d_client_ca \
  ca-file c3d_client_ca \
  peer-cert-mode require \
  authenticate once \
  ssl-c3d enabled \
  c3d-ocsp ocsp \
  c3d-drop-unknown-ocsp-status drop \
  cert-extension-includes { basic-constraints subject-alternative-name } \
  options { dont-insert-empty-fragments no-tlsv1.3 no-dtlsv1.2 }
```

Why each one matters:

- `peer-cert-mode require` — Win 11 must present a client cert; without it the handshake terminates.
- `ssl-c3d enabled` + `c3d-ocsp ocsp` + `c3d-drop-unknown-ocsp-status drop` — turn C3D on, point it at the OCSP cert-validator, and drop (don't bypass) when revocation can't be confirmed.
- `client-cert-ca` / `ca-file` = `c3d_client_ca` — the CA whose subject is sent in the `CertificateRequest` and used to verify the client cert.
- `no-tlsv1.3` — **mandatory**. C3D is incompatible with TLS 1.3 (no field for the original client cert in the 1.3 record layout). Leave it set or the topology will silently downgrade or fail.

### Server SSL profile (BIG-IP → backend nginx) — TMSH

```tmsh
create ltm profile server-ssl c3d_server_ca \
  cert c3d_forging_ca key c3d_forging_ca \
  ca-file c3d_server_ca \
  server-name c3d.nginx.com \
  ssl-c3d enabled \
  c3d-ca-cert c3d_forging_ca c3d-ca-key c3d_forging_ca \
  c3d-cert-extension-includes { basic-constraints extended-key-usage key-usage subject-alternative-name } \
  c3d-cert-lifespan 24 \
  options { dont-insert-empty-fragments no-tlsv1.3 no-dtlsv1.2 }
```

Why each one matters:

- `ssl-c3d enabled` + `c3d-ca-cert` + `c3d-ca-key` — the forging key BIG-IP uses to mint a fresh client cert to send to nginx on each flow.
- `ca-file c3d_server_ca` — trust anchor for validating *nginx's* server cert during the backend handshake.
- `server-name c3d.nginx.com` — SNI presented to nginx. Must match nginx's server cert.
- `no-tlsv1.3` — same reasoning as the client-ssl side.

## OCSP — `cert-validator-ocsp`

C3D wires up to an OCSP **cert-validator** (not the deprecated `ocsp-stapling-params`). Create it before you create the client-ssl profile:

```tmsh
create sys crypto cert-validator ocsp ocsp \
  responder-url http://10.1.1.5:2560 \
  trusted-responders c3d_client_ca \
  cache-timeout 300 \
  cache-error-timeout 300 \
  strict-resp-cert-check enabled \
  dns-resolver f5-aws-dns
```

- **`responder-url`** — **pin this**. AIA-driven discovery (leaving the URL blank and letting BIG-IP read the OCSP URL out of the client cert's `authorityInfoAccess`) is correct in theory, but requires TMM to resolve the responder hostname via the configured DNS resolver, which most labs don't have wired up. Hardcoding the URL skips DNS and AIA both, which is exactly what you want for a demo.
- **`trusted-responders c3d_client_ca`** — the CA that issued the OCSP responder cert. Because our responder is delegated by the Client CA (`out/ocsp/ocsp.crt` carries `EKU=OCSPSigning` and chains to `c3d_client_ca`), the Client CA is the trusted-responders anchor here, *not* whoever signed the user's client cert.
- **`cache-timeout 300`** — **do not leave this at `indefinite`**. If TMM ever caches a failure (DNS error, routing error, responder down), `indefinite` keeps that failure forever and poisons every subsequent client. 5 minutes is a reasonable bound.
- `strict-resp-cert-check enabled` — verifies the responder cert chain and the OCSP signature, not just the response payload.

## SSLO inbound topology

Create an inbound L3 topology in the SSLO guided config:

- **VIP**: Address `10.1.10.20`, Port `443`
- **Pool**: single member, `c3d.nginx.com:443` (or its IP if no DNS)

### Service chain — even an empty one

SSLO requires a **service chain** to be selected on the security policy's interception rule. With no chain attached the topology is structurally incomplete and TMM RSTs every connection *before* the TLS ServerHello (no log entry, no handshake stats — just an RST on the ack of the ClientHello). If you have no inspection services, create an empty service chain and bind it on the rule anyway: SSL Orchestrator ▸ Configuration ▸ Service Chains ▸ Add ▸ name it `sc_empty`, leave the service list empty, save. Then in the security policy rule, set the service chain to `sc_empty`.

### Selecting your C3D profiles in the interception rule

This is the step most C3D + SSLO walkthroughs gloss over. SSLO deploys with its own auto-built client/server-ssl profiles by default — those don't have `ssl-c3d enabled` or `c3d-ocsp` set. To get the real C3D behavior:

1. Open the topology in the SSL Orchestrator guided config.
2. Go to the **Interception Rule** step (sometimes labeled "SSL Configuration" or "TLS settings" depending on version).
3. Switch the client-ssl and server-ssl pickers from the SSLO-managed defaults to the **`c3d_bigip_server`** and **`c3d_server_ca`** profiles you created above.
4. Apply / Deploy.

After deployment, sanity-check from tmsh that the VIP is actually using your profiles, not the SSLO defaults:

```
tmsh list ltm virtual /Common/sslo_<topology>.app/sslo_<topology> profiles
```

You should see `c3d_bigip_server` (clientside) and `c3d_server_ca` (serverside) — not anything starting with `ssloP_*` or `ssloT_*_clientssl`.

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
| Edge / `openssl s_client` shows "connection reset" with **no handshake log on BIG-IP**, TLS stat counters at 0, RST arrives on the ack of the ClientHello | SSLO topology has no service chain selected on the interception rule. Create an empty service chain and attach it. |
| Handshake gets past ServerHello, BIG-IP sends a 7-byte TLS alert and FINs; LTM log shows `alert(46) unknown certificate error` | OCSP validator returning neither `good` nor a definitive `revoked/unknown`. Check `tmsh show sys crypto cert-validator ocsp ocsp` — `HTTP Errors` ≠ 0 means TMM can't reach the responder, `Successful Cache Requests` with `Good: 0` means stale failures cached forever (your `cache-timeout` is `indefinite`). |
| OCSP responder reachable via `openssl ocsp -url http://<ip>:<port>` from the BIG-IP shell, but TMM still gets HTTP errors | Routing. The BIG-IP shell uses the management interface; TMM uses its own self-IPs and routes. `tmsh show net route` — if the responder's subnet isn't there, add it: `tmsh create net route <name> network <cidr> gw <next-hop-on-a-self-IP-vlan>`. |
| `nslookup <ocsp-host>` on BIG-IP works but OCSP still fails | `nslookup` uses the host-side resolver; the OCSP validator uses its own `dns-resolver`. If you're relying on AIA, the validator's resolver must know the responder hostname — easier to pin `responder-url` and skip DNS entirely. |
| C3D enabled in profiles, deployed via SSLO, but backend sees the SSLO default cert — no forged cert | The topology is using the SSLO-managed default client/server-ssl profiles, not yours. In the interception rule, override the SSL profile pickers with your C3D-enabled profiles. Verify with `tmsh list ltm virtual ... profiles` — names should be yours, not `ssloP_*`/`ssloT_*`. |
| TLS to BIG-IP succeeds without prompting for cert | Client SSL profile's `peer-cert-mode` is `ignore` instead of `request` / `require` |
| Client cert prompted but rejected | Client CA not in trust store, or wrong CA in `client-cert-ca` / `ca-file` |
| Cert accepted but no OCSP traffic on the wire | OCSP cert-validator not attached (`c3d-ocsp` empty on client-ssl), OR `responder-url` empty *and* TMM can't resolve the AIA hostname |
| OCSP request seen, response signed by wrong CA | Responder cert wasn't issued by the configured `trusted-responders` CA (recreate via `scripts/01-create-cas.sh`) |
| Backend gets connection but says "no client cert" | C3D not enabled on server-ssl, OR `ssl_verify_client` off on nginx, OR Forging CA not loaded into nginx trust |
| Backend rejects the forged cert | nginx's `ssl_client_certificate` doesn't include Forging CA |
| Forged cert lands but with wrong subject | C3D attribute mapping in SSLO doesn't include CN — check the C3D config |
| Handshake fails only from real clients (Edge/Chrome), `openssl s_client` from BIG-IP works | Almost certainly **not** a TLS / cipher mismatch. If `openssl` from BIG-IP succeeds, the cert/profile is fine; check SSLO-specific gates (interception rule, service chain, per-flow access policy). |

## Lessons learned from standing this up

Boil it down to five things that will cost you the most time if you miss them:

1. **SSLO won't use your C3D profiles unless you override them on the interception rule.** Building `ssl-c3d enabled` profiles is necessary but not sufficient — the topology defaults to SSLO-managed profiles otherwise.
2. **SSLO needs a service chain on the rule, even an empty one.** Without it, TMM RSTs every connection on the ack of the ClientHello, with zero handshake logging.
3. **TMM has its own routing table.** Pool monitors and the BIG-IP shell can reach hosts that TMM can't. If `tmsh show net route` doesn't list the OCSP responder's subnet, OCSP queries from TMM will silently fail.
4. **`cache-timeout indefinite` is a footgun on `cert-validator-ocsp`.** One transient failure caches forever. Set it to something finite (300s is reasonable). Reset existing cache by modifying any field on the validator.
5. **Pin `responder-url` for demos.** AIA-driven OCSP discovery is the production-correct path, but it depends on TMM-side DNS that lab environments rarely have wired correctly. Pinning the URL bypasses both AIA and DNS.
