# OCSP responder — deep dive

This is the doc you actually came here for. The customer is good at SSLO config and getting blocked on the OCSP side; this section is structured so they can read it top-to-bottom and end up with a working responder, plus enough understanding to debug their own when ours isn't on the diagram.

## What an OCSP responder *is*, in two paragraphs

OCSP (Online Certificate Status Protocol, RFC 6960) lets a relying party — in our case, the BIG-IP — ask a separate service whether a specific certificate is currently revoked. It's a smaller, more current alternative to downloading a CRL: the relying party sends a tiny request containing the issuer name, issuer key hash, and the cert's serial number; the responder returns a signed answer of `good`, `revoked`, or `unknown`. The signature is what makes the answer trustworthy.

There are two ways the responder's signing key can chain to the CA whose certs it's answering for. The simpler one is "the CA signs OCSP responses directly with its own key" — easy but means the CA's signing key is online all the time, which is a security smell. The production-correct way is **delegation**: the CA issues a separate end-entity cert whose `extendedKeyUsage` includes `OCSPSigning`, gives the corresponding key to a dedicated OCSP responder host, and the responder signs OCSP responses with that key. Relying parties verify the chain CA → responder cert → response signature. This lab uses delegation.

## What we built

| Piece | File / location |
|---|---|
| Responder signing **key** | `out/ocsp/ocsp.key` |
| Responder signing **cert** | `out/ocsp/ocsp.crt` (issued by Client CA, EKU=OCSPSigning, has `id-pkix-ocsp-nocheck`) |
| Status database | `out/client-ca/index.txt` (OpenSSL CA database; updated automatically when you issue/revoke client certs) |
| Issuing CA cert | `out/client-ca/ca.crt` |
| Daemon | `openssl ocsp -port 2560 -index … -CA … -rkey … -rsigner …` running in a tiny Alpine container |
| Container build/run | `ocsp/Dockerfile`, `ocsp/start-ocsp.sh`, `ocsp/docker-compose.yml` |

## Bring it up

```bash
# Pre-req: PKI material exists (you ran scripts/01-create-cas.sh
# and scripts/04-issue-client-cert.sh)
docker compose -f ocsp/docker-compose.yml up -d
docker compose -f ocsp/docker-compose.yml logs -f
```

You should see:
```
[ocsp] listening on :2560
[ocsp]   CA    = /pki/client-ca/ca.crt
[ocsp]   index = /pki/client-ca/index.txt
[ocsp]   responder cert = /pki/ocsp/ocsp.crt (EKU=OCSPSigning)
ACCEPT 0.0.0.0:2560 PID=…
```

If it instead complains about missing files, run `scripts/01-create-cas.sh` and `scripts/04-issue-client-cert.sh` first — the responder needs the Client CA's index, the responder cert+key, and at least one client cert in the index to answer about.

## Smoke-test it

Locally on the same host, *before* you point BIG-IP at it:

```bash
# Make a request for the test-user client cert and check the response
openssl ocsp \
  -issuer  out/client-ca/ca.crt \
  -cert    out/client/test-user.crt \
  -url     http://localhost:2560 \
  -CAfile  out/client-ca/ca.crt \
  -resp_text \
  -no_nonce
```

What you're looking for in the output:
- `Response verify OK`
- `out/client/test-user.crt: good`
- A signed `Response Data` block whose certificate chain shows the responder cert with `OCSP Signing` EKU.

If you get `Response verify FAILURE`:
- Check the responder cert was issued by the same Client CA you're passing as `-CAfile`.
- Check the responder's `extendedKeyUsage` actually contains `OCSPSigning` (`openssl x509 -in out/ocsp/ocsp.crt -noout -text | grep -A1 'Extended Key'`).

If you get `unknown`:
- The serial number of the cert you're asking about isn't in `out/client-ca/index.txt`. That happens if you reissued the cert without restarting the responder, or if the index path inside the container is wrong.

## How BIG-IP finds the responder

It doesn't — the **client cert tells it**. When `scripts/04-issue-client-cert.sh` runs, it embeds an `authorityInfoAccess` extension in the cert:

```
Authority Information Access:
    OCSP - URI:http://ocsp.demo.com:2560
```

BIG-IP reads this on every connection and fires the OCSP query at the URI. **If you forget the AIA extension, OCSP just doesn't happen** — the BIG-IP will accept the cert (or fail, depending on profile) without ever asking. This is the single most common silent failure for the customer.

You can confirm AIA is present:
```bash
openssl x509 -in out/client/test-user.crt -noout -ext authorityInfoAccess
```

You can also confirm AIA is *what BIG-IP is reading*:
```bash
# On the BIG-IP, inspect what OCSP profile is doing
tcpdump -i 0.0 -nn 'host ocsp.demo.com or port 2560' -A
```

If you see no traffic, BIG-IP isn't trying to OCSP-check at all — that's almost always either:
1. AIA missing on the client cert (most common)
2. OCSP profile not attached to the client-cert-validation profile on the BIG-IP
3. BIG-IP can't resolve `ocsp.demo.com` (DNS / hosts-file)
4. BIG-IP can't reach `ocsp.demo.com:2560` (route / firewall)

## What the responder logs (and how to read it)

Because we run with `-text`, every request and response is dumped to stdout:

```
OCSP Request Data:
    Version: 1 (0x0)
    Requestor List:
        Certificate ID:
          Hash Algorithm: sha1
          Issuer Name Hash: …
          Issuer Key Hash: …
          Serial Number: 1000
…
OCSP Response Data:
    OCSP Response Status: successful (0x0)
    Response Type: Basic OCSP Response
    Version: 1 (0x0)
    Responder Id: C = US, ST = WA, L = Seattle, O = F5 C3D Demo, OU = PKI, CN = ocsp.demo.com
    …
```

Useful patterns when the customer is debugging:

- **No log lines on a connection attempt** → BIG-IP isn't sending the request. See the four causes above.
- **Request arrives, response is `unknown`** → cert serial isn't in the index. Reissue the cert or restart the responder.
- **Request arrives, response is `revoked`** → it actually was revoked. Look at `out/client-ca/index.txt` and `openssl ca -revoke`-related history.
- **Request arrives, BIG-IP reports validation failure anyway** → BIG-IP doesn't trust the responder's signing chain. Make sure the BIG-IP's OCSP profile / trust includes Client CA (which transitively trusts the responder cert that Client CA issued).

## The `id-pkix-ocsp-nocheck` extension on the responder cert

This is in our responder cert because of how OCSP recursion would otherwise work: a relying party that wants to verify the OCSP response signature would naturally want to OCSP-check the responder cert too — but the responder for *that* check would be… the same place. The `id-pkix-ocsp-nocheck` extension (OID `1.3.6.1.5.5.7.48.1.5`) tells relying parties "don't OCSP-check this cert; trust it for as long as it's valid." It's specified by RFC 6960. Verify ours has it:

```
openssl x509 -in out/ocsp/ocsp.crt -noout -text | grep -i 'OCSP No Check'
```

(`OCSP No Check:` with no value is correct — the extension takes no payload.)

## Issuing additional client certs while the responder is running

`openssl ocsp` re-reads the index file on every request, so you can issue more client certs (modifying `out/client-ca/index.txt`) and the responder will pick them up automatically. You don't need to bounce the container.

The only time you *do* need to restart is if you blew away `out/client-ca/` and recreated it from scratch — at that point the in-memory CA cert and key paths the responder loaded at startup are stale.

## Production caveats

This responder is fine for a demo and for showing the customer the wire-level behavior. It's **not** what you want for a real environment because:

- `openssl ocsp` is single-threaded, doesn't cache, and has no rate limiting.
- The responder cert is long-lived (~2 years here). Production setups rotate the responder cert weekly or daily.
- There's no monitoring, no high-availability, no alerts when the responder dies.

For production, look at OpenCA-OCSP, CFSSL's OCSP responder, NGINX's OCSP module behind a CA's PKI tooling, or commercial PKI products. The wire protocol is identical; what changes is the operational shape.
