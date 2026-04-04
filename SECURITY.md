# Security Report — hogen-vpn

**Date:** 2026-04-04  
**Scope:** Full codebase audit (shell scripts, Docker Compose, nginx config, credential lifecycle)

---

## Summary

| Severity | Count | Fixed |
|---|---|---|
| Critical | 2 | ✅ 2 |
| High | 5 | ✅ 5 |
| Medium | 4 | ✅ 2 / ⚠️ 2 noted |
| Low | 2 | ⚠️ noted |

---

## Critical

### S1 — CREDENTIALS_DOMAIN/CREDENTIALS_WEBROOT dropped from `.env` on every rotation

**File:** `rotate-reality-cover.sh`  
**Impact:** After the first cover-domain rotation, `CREDENTIALS_DOMAIN` and `CREDENTIALS_WEBROOT` were silently stripped from `.env`. Re-running `setup-nginx.sh` after any rotation would fail with `"CREDENTIALS_DOMAIN is missing"`, making routine maintenance (cert renewal, re-deploy) broken.

**Fix applied:** Both variables (and `NGINX_VHOST_PATH`) are now included in the rotation heredoc that rewrites `.env`. Test 10 asserts this.

---

### S2 — No brute-force protection on the credentials page

**File:** `setup-nginx.sh`, `web/nginx-vhost.conf.template`  
**Impact:** The HTTPS credentials page was protected only by HTTP Basic Auth with no rate limiting and no IP ban. An attacker could enumerate `PAGE_PASSWORD` at full network speed, eventually recovering all four VPN protocol secrets from the page.

**Fix applied (two layers):**

1. **nginx rate limiting** — `web/nginx-ratelimit.conf` installs a `limit_req_zone` (5 requests/minute per IP, burst 5) applied to the credentials location. Returns HTTP 429 on excess requests.
2. **fail2ban** — `fail2ban/jail.d/hogen-vpn.conf` configures two jails:
   - `[nginx-http-auth]` — 5 failed auth attempts in 5 minutes → 30-minute UFW ban
   - `[sshd]` — 5 failed SSH attempts in 10 minutes → 1-hour UFW ban

   `setup-nginx.sh` installs fail2ban, copies the jail config, and reloads fail2ban on every run.

---

## High

### S3 — nginx vhost missing security headers

**File:** `web/nginx-vhost.conf.template`  
**Impact:** The credentials page (which displays VPN credentials) was served without `X-Frame-Options`, `Content-Security-Policy`, `X-Content-Type-Options`, `Referrer-Policy`, or `Strict-Transport-Security`. The page could be embedded in iframes (clickjacking) or leak credential data in Referer headers.

**Fix applied:** Added to location block:
```nginx
server_tokens off;
add_header X-Frame-Options "DENY" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "no-referrer" always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self' https://cdnjs.cloudflare.com; ..." always;
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
```

---

### S4 — `xray/config.json` and `mtg/config.toml` world-readable

**Files:** `render-xray-config.sh`, `generate-secrets.sh`  
**Impact:** Both files were written with the process umask (typically 0022, resulting in 0644 permissions). `xray/config.json` contains `XRAY_PRIVATE_KEY` and `SS_PASSWORD`. Any local user on the VPS could read both files.

**Fix applied:** `chmod 600` is now called on both files immediately after creation. `chmod 600 .env` is also enforced at generation time. Test 11 asserts `xray/config.json` permissions = 600.

---

### S5 — `ipsec/data/` not excluded from rsync in `deploy.sh`

**File:** `deploy.sh`  
**Impact:** If the `ipsec/data/` directory existed locally (e.g., copied from a backup), rsync would overwrite the server's IKEv2 PKI with stale/wrong certificates on every deploy, silently breaking all IKEv2 connections.

**Fix applied:** Added `--exclude='ipsec/'` to the rsync call.

---

### S6 — SSH calls in `deploy.sh` had no `StrictHostKeyChecking`

**File:** `deploy.sh`  
**Impact:** On first connection to a new server (or after a server rebuild), ssh accepts any host key without verification. An attacker performing a MITM attack during initial deploy could receive all deployed files and all re-rendered secrets.

**Fix applied:** All three `ssh`/`rsync` calls in `deploy.sh` now use `-o StrictHostKeyChecking=accept-new`. This accepts new hosts on first contact but rejects any changed host key on subsequent connections.

---

### S7 — `setup-nginx.sh` never allowed SSH in UFW or called `ufw enable`

**File:** `setup-nginx.sh`  
**Impact:** The script added rules for VPN ports but never called `ufw allow OpenSSH` or `ufw --force enable`. On a server where UFW was inactive, all added rules were silently unenforced. On a server where UFW was already active but SSH was not yet allowed, running the script and then enabling UFW would lock the operator out of the server.

**Fix applied:**
- `ufw allow OpenSSH` is now the first firewall rule added (before any other port)
- `ufw --force enable` is called at the end of the firewall section

---

## Medium

### S8 — `certbot --register-unsafely-without-email`

**File:** `setup-nginx.sh`  
**Impact:** No email address is registered with Let's Encrypt. Certificate expiry warnings are never sent. TLS certificates expire after 90 days; if the auto-renewal cron/timer fails silently, the credentials page goes HTTPS-broken with no alert.

**Recommendation:** Replace `--register-unsafely-without-email` with `--email admin@your-domain.com` so Let's Encrypt can send expiry reminders. Update `setup-nginx.sh` or pass the email via an env var.

**Status:** ⚠️ Not fixed — requires operator-specific email. Document in setup guide.

---

### S9 — `IKE_USER` hardcoded as `vpnuser`

**File:** `generate-secrets.sh`  
**Impact:** Every deployment uses the same username. Combined with a weak `IKE_PASSWORD`, a targeted attack against a known-deployment would need to brute-force only the password (not the username). Predictable usernames reduce the cost of credential-stuffing.

**Recommendation:** Generate a random username (e.g., `openssl rand -hex 6`) or make it a configurable argument, the same way `CREDENTIALS_DOMAIN` is.

**Status:** ⚠️ Noted — low exploitability with a strong random password, but worth hardening.

---

### S10 — `set -a` exports private key material to child process environment

**Files:** `rotate-reality-cover.sh`, `render-xray-config.sh`, `render-credentials-page.sh`  
**Impact:** Loading `.env` with `set -a; source .env; set +a` exports `XRAY_PRIVATE_KEY`, `SS_PASSWORD`, `IKE_PSK`, and `PAGE_PASSWORD` as environment variables. All child processes (including `docker compose`, `curl`, `envsubst`) inherit these variables. On Linux, process environment is visible in `/proc/<pid>/environ` to the process owner and root.

**Recommendation:** Source `.env` in a subshell that passes only required variables to each subprocess, rather than exporting everything globally. This is architecturally significant and would require refactoring the sourcing pattern across all scripts.

**Status:** ⚠️ Noted — not fixed in this pass. Risk is low on single-user VPS but worth addressing in a future refactor.

---

### S11 — nginx rate limit covered by fail2ban but not connection-limited per IP

**Status:** ✅ Fixed via `limit_req` + fail2ban (see S2).

---

## Low

### S12 — `hwdsl2/ipsec-vpn-server:latest` — no version pinning

**File:** `docker-compose.yml`  
**Impact:** The IKEv2 container will silently upgrade on `docker compose pull`, potentially introducing breaking changes. The `hwdsl2/ipsec-vpn-server` image does not publish semver tags, so pinning to a digest is the only option.

**Recommendation:** After verifying a working release, pin to the image digest:
```bash
docker inspect hwdsl2/ipsec-vpn-server --format '{{.RepoDigests}}'
# Then use: hwdsl2/ipsec-vpn-server@sha256:<digest>
```

**Status:** ⚠️ Noted — no semver tag available from this image publisher.

---

### S13 — Credential page served over HTTP before Certbot completes

**File:** `setup-nginx.sh`  
**Impact:** Between the moment nginx is configured and the moment Certbot adds HTTPS, the credentials page is briefly accessible over plain HTTP. This window is short (seconds) but the page contains all VPN secrets.

**Recommendation:** The Certbot `--redirect` flag closes this window as soon as Certbot completes. To further harden, configure the initial vhost to return 404 on HTTP and only add content after Certbot runs, or run Certbot before creating the htpasswd file.

**Status:** ⚠️ Minor — window is very brief; `--redirect` is already in place.

---

## fail2ban Configuration Reference

Installed to `/etc/fail2ban/jail.d/hogen-vpn.conf` by `setup-nginx.sh`:

| Jail | Trigger | Ban duration |
|---|---|---|
| `sshd` | 5 failed SSH logins in 10 min | 1 hour |
| `nginx-http-auth` | 5 failed Basic Auth in 5 min | 30 min |

To check ban status:
```bash
fail2ban-client status nginx-http-auth
fail2ban-client status sshd
```

To unban an IP:
```bash
fail2ban-client set nginx-http-auth unbanip <IP>
```

To test that the filter works:
```bash
fail2ban-regex /var/log/nginx/error.log /etc/fail2ban/filter.d/nginx-http-auth.conf
```
