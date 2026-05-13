# Win 11 client setup

This is the user-side of the demo. Two artifacts get installed:

1. **Server CA root cert** — so Windows trusts the BIG-IP's server cert.
2. **Client identity PFX** — the cert + key the user presents during mTLS, plus the Client CA bundled in for chain-building.

## Files you'll move to the Win 11 box

From `out/`:

| Source | Destination on Win 11 | Purpose |
|---|---|---|
| `out/server-ca/ca.crt` | anywhere temporary | Trust the BIG-IP's server cert |
| `out/client/test-user.pfx` | anywhere temporary | The user's client identity (password from `pki.conf`'s `PFX_PASSWORD`, default `changeme`) |

USB stick, scp, copy-paste, your call. Treat the `.pfx` like a password.

## DNS / hosts file

The browser must resolve `c3d.app.com` to `10.1.10.20`. Easiest path on a lab Win 11:

1. Open Notepad **as administrator**.
2. Open `C:\Windows\System32\drivers\etc\hosts`.
3. Add a line:
   ```
   10.1.10.20    c3d.app.com
   ```
4. Save. Confirm with `nslookup c3d.app.com` from a regular PowerShell — it should return `10.1.10.20`.

## Install the Server CA

So Windows trusts the BIG-IP's server cert without browser warnings:

1. Double-click `ca.crt` (rename to `c3d-server-ca.crt` first if you want).
2. **Install Certificate** ▸ **Local Machine** ▸ **Next** ▸ **Place all certificates in the following store** ▸ **Browse** ▸ **Trusted Root Certification Authorities** ▸ **OK** ▸ **Next** ▸ **Finish**.
3. Confirm: `certmgr.msc` ▸ Trusted Root Certification Authorities ▸ Certificates — `C3D Demo Server CA` should be listed.

## Install the user's client identity (.pfx)

Either of two stores, both work:

- **Personal — Current User** (recommended for browser-driven mTLS demos)
- **Personal — Local Machine** (if you want any user on the box to use the same identity)

Steps for Current User:

1. Double-click `test-user.pfx`.
2. **Current User** ▸ **Next**.
3. **File name**: pre-filled. **Next**.
4. **Password**: enter `changeme` (or whatever `PFX_PASSWORD` was set to). Leave the import options at defaults; **enable strong protection** is fine. **Next**.
5. **Place all certificates in the following store** ▸ **Browse** ▸ **Personal** ▸ **OK** ▸ **Next** ▸ **Finish**.
6. Confirm: `certmgr.msc` ▸ Personal ▸ Certificates — `test-user` should be listed, issued by `C3D Demo Client CA`.

> The Client CA bundled inside the PFX gets installed automatically into Intermediate Certification Authorities. That's intentional — the chain validation needs it.

## Test

### Browser (Edge or Chrome)

1. Browse to `https://c3d.app.com/`.
2. The browser will prompt for a client certificate. Pick `test-user`. Confirm.
3. You should see plain-text page content from nginx that includes:
   ```
   C3D backend reached.

   Forged client subject: CN=test-user,...
   Forged cert verify:    SUCCESS
   ```

### PowerShell with curl (sometimes faster for debug)

```powershell
# From PowerShell on Win 11 — uses the cert installed in Current User\Personal
curl.exe --cert-type P12 `
  --cert "$env:TEMP\test-user.pfx:changeme" `
  https://c3d.app.com/
```

## Common stumbles

| Symptom | Most likely cause |
|---|---|
| Browser says "your connection isn't private" | Server CA not installed in Trusted Root Certification Authorities |
| Browser doesn't prompt for a client cert | BIG-IP's Client SSL profile is set to `ignore`, not `request`/`require` |
| Browser prompts but no certs appear | Client cert not installed in Personal store, OR Client CA not in Intermediate store |
| Page loads but `Forged cert verify: FAILURE` | nginx isn't trusting the Forging CA — see [`BIGIP-SSLO-CONFIG.md`](./BIGIP-SSLO-CONFIG.md) backend section |
| Page loads but subject is wrong / blank | C3D attribute mapping on the BIG-IP isn't preserving CN |
| `https://c3d.app.com/` doesn't resolve at all | hosts-file entry missing or a DNS resolver in front of you is masking it (`ipconfig /flushdns` in admin PowerShell) |
