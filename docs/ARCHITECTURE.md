# Architecture — what lives where, and why

## Topology

```
   Win 11 client                           BIG-IP (TMOS 21)             Backend nginx
  ┌──────────────┐  TLS + mTLS         ┌──────────────────┐ TLS         ┌──────────────┐
  │ c3d.app.com  │ ──────────────────▶ │  c3d.app.com     │ ──────────▶ │c3d.nginx.com │
  │ + client cert│                     │  10.1.10.20      │ forged cert │  trusts      │
  │ (Client CA)  │ ◀────────────────── │  SSLO + C3D      │ from        │  Forging CA  │
  └──────────────┘                     └────────┬─────────┘ Forging CA  └──────────────┘
                                                │
                                    OCSP query  │
                                                ▼
                                       ┌──────────────────┐
                                       │  ocsp.demo.com   │
                                       │   :2560          │
                                       │  (OpenSSL,       │
                                       │   delegated by   │
                                       │   Client CA)     │
                                       └──────────────────┘
```

## The four certificate authorities

| CA | Issued by this lab? | Issues | Trusted by | Private key on |
|---|---|---|---|---|
| **Server CA** | yes (`out/server-ca/`) | BIG-IP's server cert, backend's server cert | Win 11 trust store (Server CA root); BIG-IP trust store (for backend re-encrypt validation) | offline / disposable |
| **Client CA** | yes (`out/client-ca/`) | Win 11 client cert; OCSP responder cert | BIG-IP client-cert-verification trust profile | offline / disposable |
| **Forging CA** | yes (`out/forging-ca/`) | (no end-entity certs in this repo — BIG-IP forges them at runtime) | Backend nginx (must trust this for the C3D leg to validate) | **uploaded to BIG-IP** |
| **OCSP responder cert** | yes (`out/ocsp/`) — *not a CA, an end-entity cert delegated by Client CA* | nothing — it just signs OCSP responses | BIG-IP (implicitly, as long as it chains back to Client CA which BIG-IP trusts) | the OCSP responder host |

## End-entity certificates

| Cert | Issued by | Goes on | Notable extensions |
|---|---|---|---|
| BIG-IP server cert | Server CA | BIG-IP, attached to the SSL profile on the inbound VS | `subjectAltName = DNS:c3d.app.com, IP:10.1.10.20`, `EKU=serverAuth` |
| Backend nginx server cert | Server CA | nginx | `subjectAltName = DNS:c3d.nginx.com`, `EKU=serverAuth` |
| Win 11 client cert | Client CA | Win 11 user store | `EKU=clientAuth`, `authorityInfoAccess=OCSP;URI:http://ocsp.demo.com:2560` |
| OCSP responder cert | Client CA (delegation) | OCSP responder host | `EKU=OCSPSigning`, `id-pkix-ocsp-nocheck` |

## Why three CAs and not one

A single CA that signs everything *would* "work" but it muddles authorization in a way that makes failures hard to diagnose for the customer:

- The **Server CA** says "this hostname is who they claim to be." Win 11 trusts it; BIG-IP trusts it for backend re-encrypt validation. **It does not validate clients.**
- The **Client CA** says "this person is who they claim to be." BIG-IP trusts it on the client-cert-verification profile. **It does not validate servers.**
- The **Forging CA** is the *only* CA whose private key lives on the BIG-IP. It exists so the backend can distinguish "this came through SSLO and got identity-preserved" from "someone connected directly with a real client cert." Mixing this with Server CA would mean the backend has no way to tell those apart.

## The C3D step-by-step

1. Win 11 opens TLS to `c3d.app.com` (which resolves to `10.1.10.20`).
2. BIG-IP presents its server cert (`bigip.crt`, signed by Server CA). Win 11 validates against its trust store.
3. BIG-IP requests a client cert. Win 11 sends `test-user.crt` (signed by Client CA, with AIA pointing at `http://ocsp.demo.com:2560`).
4. **BIG-IP fires an OCSP request** to `ocsp.demo.com:2560`. The responder reads `out/client-ca/index.txt`, sees the cert is valid, signs an OCSP response with `out/ocsp/ocsp.key`, returns `good`.
5. BIG-IP terminates the client's TLS. The original client cert and the OCSP `good` verdict are now part of the SSLO context for this flow.
6. BIG-IP opens a new TLS connection to the backend (`c3d.nginx.com`).
7. **C3D fires here.** BIG-IP forges a *new* client certificate using the Forging CA's private key, copying the original client cert's CN (and configurable other attributes) into the forgery.
8. BIG-IP presents the forged cert to nginx during this new TLS handshake.
9. nginx validates the forged cert against its `ssl_client_certificate` trust file (`forging-ca.crt`). Forging CA → trusted, validation succeeds.
10. nginx logs `$ssl_client_s_dn` — the original CN — and returns the response.

## What BIG-IP needs uploaded

- **Server cert + key** (`out/bigip/bigip.crt`, `bigip.key`) → SSL profile on the inbound VS.
- **Server CA** (`out/server-ca/ca.crt`) → trust store, so BIG-IP can validate the *backend's* server cert during re-encrypt.
- **Client CA** (`out/client-ca/ca.crt`) → client-cert-verification profile, so BIG-IP can validate the Win 11 client cert.
- **Forging CA cert + key** (`out/forging-ca/ca.crt` + `ca.key`, or `forging-ca.pfx`) → the SSLO C3D configuration, so BIG-IP can mint forged certs.
- **OCSP responder URL**: implicitly via the AIA in client certs. No upload, but BIG-IP must be able to reach `ocsp.demo.com:2560`.

## Where each piece runs

- **PKI scripts**: anywhere with OpenSSL (your laptop, a CI runner, the same VM as nginx — doesn't matter).
- **OCSP responder** (Docker): typically the same Ubuntu VM as nginx for simplicity, exposed as `ocsp.demo.com:2560` to BIG-IP.
- **Backend nginx** (Docker): Ubuntu VM, port 443.
- **BIG-IP**: hardware or VE; details in [`BIGIP-SSLO-CONFIG.md`](./BIGIP-SSLO-CONFIG.md).
- **Win 11 client**: details in [`CLIENT-WIN11.md`](./CLIENT-WIN11.md).

## DNS resolution

The Win 11 client must resolve `c3d.app.com` to `10.1.10.20`. The BIG-IP must resolve `ocsp.demo.com` and `c3d.nginx.com` to the right backend hosts. Easiest path is the lab DNS server you control; failing that, host-file entries on each of the three machines.
