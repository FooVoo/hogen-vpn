# telegram-proxy

Self-hosted censorship bypass stack. Two services:

- **MTProxy** — Telegram-only proxy with domain-fronting obfuscation ([mtg v2](https://github.com/9seconds/mtg))
- **VLESS+Reality** — full VPN for all traffic ([Xray-core](https://github.com/XTLS/Xray-core))

A password-protected credentials page (HTTPS) shows QR codes, connection links, and per-field copy buttons for all clients.

## Requirements

- Ubuntu VPS outside your target region (1 vCPU, 1 GB RAM is enough)
- A domain pointing to the server
- Existing nginx + Certbot (the credentials page is added as a new vhost)

## First-time setup

```bash
# 1. Copy project to server
rsync -az ./ user@yourserver:/opt/vpn/

# 2. Install Docker
ssh user@yourserver "curl -fsSL https://get.docker.com | sh"

# 3. Generate all secrets
ssh user@yourserver "cd /opt/vpn && ./generate-secrets.sh your.domain.com"

# 4. Set up nginx vhost + SSL + firewall
ssh user@yourserver "cd /opt/vpn && ./setup-nginx.sh"

# 5. Start containers
ssh user@yourserver "cd /opt/vpn && docker compose up -d"
```

Credentials page will be at `https://your.domain.com`.
Login and password are printed at the end of step 3.

## Ongoing deploys

Edit files locally, then sync to the server:

```bash
./deploy.sh
```

If you changed the HTML template, regenerate the credentials page on the server:

```bash
ssh user@yourserver "cd /opt/vpn && ./setup-nginx.sh"
```

If you changed `docker-compose.yml` or container configs:

```bash
ssh user@yourserver "cd /opt/vpn && docker compose up -d"
```

## Ports

| Port | Service |
|---|---|
| 443 | Existing nginx (not touched) |
| 2083 | MTProxy (Telegram) |
| 8443 | VLESS (full VPN) |

## Adapting for a different server

`setup-nginx.sh` has the domain hardcoded. Edit `DOMAIN=` at the top before running on a new server. Everything else is driven by `.env` which `generate-secrets.sh` creates fresh per server.

## Client apps

**Telegram MTProxy** — built into Telegram, no extra app needed. Use the link or QR from the credentials page.

**VLESS:**

| Platform | App |
|---|---|
| iPhone | V2Box · Shadowrocket · Streisand |
| Android | v2rayNG |
| Windows | v2rayN |
| macOS | Hiddify |

Import via the VLESS URI link or QR code from the credentials page.

## Files

```
generate-secrets.sh     — run once per server, creates .env + configs
setup-nginx.sh          — nginx vhost, Certbot SSL, firewall rules, HTML generation
deploy.sh               — rsync local files to server (excludes secrets)
docker-compose.yml      — mtg + xray containers
web/
  index.html.template   — credentials page (envsubst variables)
  nginx-vhost.conf      — nginx site config (HTTP, Certbot adds HTTPS)
  nginx.conf            — fallback nginx config for standalone Docker use
  entrypoint.sh         — entrypoint for standalone Docker web container
.env.example            — template showing all required variables
```

Secrets (`.env`, `mtg/config.toml`, `xray/config.json`) are gitignored.
