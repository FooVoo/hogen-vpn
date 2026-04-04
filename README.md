# hogen-vpn

Self-hosted censorship bypass stack — four protocols in one deployment.

| Protocol | Transport | Use case |
|---|---|---|
| **MTProxy** | TCP 2083 | Telegram-only, built into Telegram |
| **VLESS+Reality** | TCP 8443 | Full VPN for all traffic, highest stealth |
| **Shadowsocks 2022** | TCP+UDP 8388 | Full VPN, wide client support |
| **IKEv2/IPSec** | UDP 500+4500 | Native client on iOS, macOS, Windows |

A password-protected HTTPS credentials page shows QR codes, connection URIs, and per-field copy buttons for every protocol.

## How it works

- **MTProxy** ([mtg v2](https://github.com/9seconds/mtg)) runs in Docker, obfuscates Telegram traffic to look like HTTPS to a real domain.
- **Xray** ([xray-core v26.3.27](https://github.com/XTLS/Xray-core)) serves two inbounds from one container: VLESS+Reality on 8443 (impersonates a real TLS site) and Shadowsocks 2022 on 8388.
- **IKEv2** ([hwdsl2/ipsec-vpn-server](https://github.com/hwdsl2/docker-ipsec-vpn-server)) runs in Docker with `VPN_IKEV2_ONLY=yes` — accepts EAP (username/password) auth, no client app required on iOS/macOS/Windows.
- **nginx** (host) serves a password-protected HTTPS page at your domain with all connection details.
- A **systemd timer** rotates the VLESS+Reality cover domain every 2 hours, TLS-checks the new candidate against a pool of 35 domains (20 international + 15 Russian), and reloads Xray automatically. After each rotation users should re-import the VLESS link.

## Requirements

- Ubuntu/Debian VPS outside the target region (1 vCPU, 1 GB RAM sufficient)
- A domain name pointing to the server (for the credentials page SSL)
- nginx + Certbot on the host (the project adds a new vhost, does not replace nginx)
- Docker installed

## First-time setup

### 1. Copy project to server

```bash
# Configure deployment target (copy and edit .deploy.env.example)
cp .deploy.env.example .deploy.env
# Set DEPLOY_HOST=user@your-server-ip, DEPLOY_REMOTE_DIR, DEPLOY_KEY as needed
source .deploy.env && ./deploy.sh
```

Or manually:
```bash
rsync -az --exclude='.env' --exclude='mtg/' --exclude='xray/' --exclude='ipsec/' \
  ./ user@yourserver:/opt/vpn/
```

### 2. Install Docker on the server

```bash
ssh user@yourserver "curl -fsSL https://get.docker.com | sh"
```

### 3. Generate all secrets

```bash
ssh user@yourserver "cd /opt/vpn && ./generate-secrets.sh <SERVER_IP> [REALITY_COVER_DOMAIN] [CREDENTIALS_DOMAIN]"
```

- `SERVER_IP` — the VPS public IP address (required)
- `REALITY_COVER_DOMAIN` — optional: pin a specific initial REALITY cover domain; if omitted, one is randomly selected from the pool
- `CREDENTIALS_DOMAIN` — optional: your domain name for the credentials page; also sets `CREDENTIALS_DOMAIN` in `.env` (required by `setup-nginx.sh`)

The page login credentials are printed at the end of this step.

### 4. Set up nginx vhost + SSL + firewall

```bash
ssh user@yourserver "cd /opt/vpn && sudo ./setup-nginx.sh"
```

This configures the nginx vhost (reading `CREDENTIALS_DOMAIN` from `.env`), obtains a Let's Encrypt certificate, opens all required UFW ports, renders the credentials page, and installs the 2-hour rotation timer.

### 5. Start containers

```bash
ssh user@yourserver "cd /opt/vpn && docker compose up -d"
```

### 6. Export IKEv2 client profile (first run only)

After the `ipsec` container has started (~60 seconds):

```bash
ssh user@yourserver "docker exec ipsec ikev2.sh --export-client client"
```

This generates `./ipsec/data/client.mobileconfig` (iOS/macOS) and `client.sswan` (Android/strongSwan) with the CA certificate embedded. Distribute these files to users via a secure channel.

The credentials page also shows all IKEv2 parameters for manual setup.

## Ongoing deploys

```bash
source .deploy.env && ./deploy.sh
```

`deploy.sh` syncs project files, re-renders the Xray config and credentials page, and restarts containers on the server automatically.

To change REALITY rotation interval or disable it, edit `XRAY_ROTATE_HOURS` in `.env` on the server, then rerun `setup-nginx.sh`:

```bash
# Disable rotation:
ssh user@yourserver "sed -i 's/^XRAY_ROTATE_HOURS=.*/XRAY_ROTATE_HOURS=0/' /opt/vpn/.env && cd /opt/vpn && sudo ./setup-nginx.sh"
```

To rebuild container configs without a full deploy:

```bash
ssh user@yourserver "cd /opt/vpn && ./render-xray-config.sh && docker compose restart xray"
```

## Cover domain rotation

The VLESS+Reality `sni`/`dest` pair rotates every **2 hours** via a systemd timer (`xray-rotate.timer`). The rotation script:

1. Shuffles the 35-domain pool (`XRAY_COVER_DOMAINS` in `.env`)
2. TLS-checks each candidate — skips any domain that doesn't respond on TLS
3. Picks the first reachable domain different from the current one
4. Atomically rewrites `.env`, re-renders `xray/config.json` and the credentials page, then restarts Xray

After rotation, **previously imported VLESS profiles stop working** because the SNI changed. Users must reopen the credentials page and re-import the link or QR code. Shadowsocks and IKEv2 are unaffected by rotation.

Set `XRAY_ROTATE_HOURS=0` (and rerun `./setup-nginx.sh`) to disable automatic rotation and keep profiles stable.

## Ports

| Port | Protocol | Service |
|---|---|---|
| 80, 443 | TCP | nginx (credentials page + Let's Encrypt) |
| 2083 | TCP | MTProxy (Telegram) |
| 8443 | TCP | VLESS+Reality (full VPN) |
| 8388 | TCP+UDP | Shadowsocks 2022 |
| 500 | UDP | IKEv2/IPSec (ISAKMP) |
| 4500 | UDP | IKEv2/IPSec (NAT-T) |

## Client apps

**MTProxy** — built into Telegram. Tap the `tg://` link from the credentials page.

**VLESS+Reality:**
| Platform | App |
|---|---|
| Android | [v2rayNG](https://github.com/2dust/v2rayNG) |
| iPhone | [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118) · [Streisand](https://apps.apple.com/app/streisand/id6450534064) · V2Box |
| Windows | [v2rayN](https://github.com/2dust/v2rayN) |
| macOS | [Hiddify](https://github.com/hiddify/hiddify-app) |

Import via VLESS URI or QR code from the credentials page.

**Shadowsocks 2022** (cipher: `2022-blake3-aes-256-gcm`):
| Platform | App |
|---|---|
| Android | v2rayNG · [Shadowsocks Android](https://github.com/shadowsocks/shadowsocks-android) |
| iPhone | Shadowrocket · Potatso Lite |
| Windows | v2rayN |
| macOS | Hiddify |

Import via SS URI or QR code from the credentials page.

**IKEv2/IPSec** — no extra app needed on most platforms:
| Platform | How to connect |
|---|---|
| iPhone / macOS | Settings → VPN → Add Configuration → IKEv2 (or install `.mobileconfig` profile) |
| Android | [strongSwan](https://play.google.com/store/apps/details?id=org.strongswan.android) app → import `.sswan` profile |
| Windows | Settings → Network → VPN → Add a VPN connection → IKEv2 |

Auth type: **EAP (username + password)**. All parameters are shown on the credentials page.

## Files

```
generate-secrets.sh         — one-time setup: creates .env, mtg/config.toml, xray/config.json
render-xray-config.sh       — rebuilds xray/config.json from .env (VLESS + Shadowsocks inbounds)
render-credentials-page.sh  — rebuilds the HTTPS credentials page from .env
rotate-reality-cover.sh     — rotates VLESS cover domain, TLS-checks candidates, reloads Xray
setup-nginx.sh              — nginx vhost, Certbot SSL, UFW rules, rotation timer install
deploy.sh                   — rsync local files → server, re-renders configs, restarts containers
test-rotation.sh            — 11-assertion test suite for the rotation mechanism
docker-compose.yml          — mtg + xray + ipsec containers
.env.example                — all required .env variables with descriptions
.deploy.env.example         — local deploy overrides (DEPLOY_HOST, DEPLOY_KEY, etc.) — not synced
web/
  index.html.template       — credentials page template (envsubst variables)
  nginx-vhost.conf.template — nginx vhost template (rendered with CREDENTIALS_DOMAIN at setup time)
  nginx.conf                — standalone Docker web container nginx config
  entrypoint.sh             — entrypoint for standalone Docker web container mode
```

Generated files (gitignored): `.env`, `mtg/config.toml`, `xray/config.json`, `ipsec/data/`, rendered HTML.

## Environment variables

`.env` (server-side, generated by `generate-secrets.sh`):

| Variable | Description |
|---|---|
| `SERVER_IP` | VPS public IP |
| `MTG_SECRET`, `MTG_PORT`, `MTG_LINK` | MTProxy credentials |
| `XRAY_UUID`, `XRAY_PRIVATE_KEY`, `XRAY_PUBLIC_KEY`, `XRAY_SHORT_ID`, `XRAY_SNI`, `XRAY_DEST` | VLESS+Reality parameters |
| `XRAY_COVER_DOMAINS` | Comma-separated rotation pool (35 domains) |
| `XRAY_ROTATE_HOURS` | Rotation interval in hours (`0` = disabled, default `2`) |
| `VLESS_URI` | Full VLESS connection URI |
| `SS_METHOD`, `SS_PORT`, `SS_PASSWORD`, `SS_URI` | Shadowsocks 2022 credentials |
| `IKE_PSK`, `IKE_USER`, `IKE_PASSWORD` | IKEv2 credentials |
| `PAGE_USER`, `PAGE_PASSWORD` | Credentials page HTTP Basic Auth |
| `CREDENTIALS_DOMAIN` | Domain for the nginx vhost (required by `setup-nginx.sh`) |
| `CREDENTIALS_WEBROOT` | Web root path (default `/var/www/vpn`) |

`.deploy.env` (local machine, not synced):

| Variable | Description | Default |
|---|---|---|
| `DEPLOY_HOST` | `user@hostname` SSH target | `root@universal.ramilkarimov.me` |
| `DEPLOY_REMOTE_DIR` | Remote project directory | `/opt/vpn` |
| `DEPLOY_KEY` | Local SSH private key path | `~/.ssh/vpn_deploy` |
