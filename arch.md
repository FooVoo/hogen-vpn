# Hogen VPN Architecture Report

## Executive summary

This repository is an infrastructure-first deployment bundle for a self-hosted censorship-bypass stack. It combines four protocols:

1. **MTProxy** for Telegram-only traffic (domain-fronting obfuscation)
2. **VLESS + Reality (Xray)** for full-device VPN traffic with TLS impersonation
3. **Shadowsocks 2022** for full-device VPN traffic with wide client support
4. **IKEv2/IPSec** for full-device VPN using the platform-native client on iOS, macOS, and Windows

There is **no traditional backend application** in this project: no API server, no database, no package-managed frontend, and no build pipeline. The repository is mostly shell automation, container runtime configuration, and a static HTML template rendered with environment variables during deployment.

## Repository structure

| Path | Role |
| --- | --- |
| `README.md` | High-level setup, protocol overview, and deployment instructions |
| `docker-compose.yml` | Starts mtg, xray, and ipsec containers |
| `generate-secrets.sh` | One-time secret/config generator for `.env`, `mtg/config.toml`, and `xray/config.json` |
| `render-xray-config.sh` | Rebuilds `xray/config.json` from `.env` (VLESS+Reality + Shadowsocks inbounds) |
| `render-credentials-page.sh` | Rebuilds the HTTPS credentials page from `.env` |
| `rotate-reality-cover.sh` | Rotates VLESS cover domain, TLS-checks candidates, rewrites `.env`, reloads Xray |
| `setup-nginx.sh` | Host-level setup: vhost, Certbot SSL, UFW, htpasswd, rotation timer |
| `deploy.sh` | Rsync-based deployment from local machine to server |
| `test-rotation.sh` | 11-assertion test suite for the rotation mechanism |
| `.env.example` | Template for all required `.env` variables |
| `.deploy.env.example` | Template for local deploy overrides (not synced to server) |
| `setup.md` | Comprehensive server setup guide (Docker install through verification) |
| `vless-setup.md` | Manual VLESS+Reality setup reference |
| `user-manual.md` | End-user connection guide in Russian (all 4 protocols) |
| `web/index.html.template` | Credentials page template rendered with `envsubst` (4 protocol cards) |
| `web/nginx-vhost.conf.template` | nginx vhost template rendered with `CREDENTIALS_DOMAIN` at setup time |
| `web/nginx.conf` | Standalone nginx config for an optional containerized web mode |
| `web/entrypoint.sh` | Entrypoint for the optional standalone web container mode |

## High-level component model

```mermaid
flowchart TD
    A[Admin workstation] -->|deploy.sh / rsync| B[/opt/vpn on VPS]
    B -->|generate-secrets.sh| C[Generated secrets and configs]
    C --> D[.env]
    C --> E[mtg/config.toml]
    C --> F[xray/config.json]
    D --> G[setup-nginx.sh]
    D --> H[docker compose up -d]
    G --> I[Host nginx + Certbot + htpasswd + rendered index.html]
    G --> T[systemd xray-rotate.timer every 2h]
    T --> R[rotate-reality-cover.sh]
    R --> D
    E --> J[MTProxy container — port 2083]
    F --> K[Xray container — VLESS port 8443, SS port 8388]
    D --> L[IKEv2/IPSec container — ports 500/4500 UDP]

    M[Browser user] -->|HTTPS 443| I
    N[Telegram client] -->|TCP 2083| J
    O[VLESS client] -->|TCP 8443| K
    P[Shadowsocks client] -->|TCP+UDP 8388| K
    Q[IKEv2 client] -->|UDP 500/4500| L
```

## Runtime architecture

### 1. Host-level services

The standard deployment relies on the VPS host for the following:

- **nginx** as the HTTPS web server for the credentials page
- **Certbot** to provision and inject TLS configuration into the nginx vhost
- **ufw** to open all required ports (80, 443, 2083, 8388, 8443, 500/udp, 4500/udp)
- **systemd timer** (`xray-rotate.timer`) to run `rotate-reality-cover.sh` every 2 hours
- **filesystem storage** for generated secrets, rendered HTML, and the htpasswd file

### 2. Containerized services

`docker-compose.yml` defines three long-running services:

| Service | Image | Host port(s) | Role |
| --- | --- | --- | --- |
| `mtg` | `nineseconds/mtg:2` | `2083 → 3128` | Telegram MTProxy with domain-fronting secret |
| `xray` | `ghcr.io/xtls/xray-core:26.3.27` | `8443`, `8388 tcp+udp` | VLESS+Reality inbound (8443) + Shadowsocks 2022 inbound (8388) |
| `ipsec` | `hwdsl2/ipsec-vpn-server` | `500/udp`, `4500/udp` | IKEv2/IPSec with EAP auth, `VPN_IKEV2_ONLY=yes` |

All containers use:

- `restart: unless-stopped`
- `healthcheck` with appropriate test commands and start periods
- read-only mounted config files (mtg, xray) or persistent data volume (ipsec PKI)

The `ipsec` container reads credentials from docker-compose's automatic `.env` interpolation (`${IKE_PSK}`, `${IKE_USER}`, `${IKE_PASSWORD}`). On first start it generates PKI into `./ipsec/data/`.

The `xray` container serves **two inbounds** from a single config:
- VLESS+Reality on `8443` with `xtls-rprx-vision` flow and TLS impersonation
- Shadowsocks 2022 on `8388` with `2022-blake3-aes-256-gcm` cipher

### 3. Optional standalone web mode

`web/nginx.conf` and `web/entrypoint.sh` define an alternate way to serve the credentials page from a container. That mode is **not wired into `docker-compose.yml`** and is an auxiliary deployment option for environments without a host nginx.

## Network and request flow

### Credentials page flow

1. Browser connects to the public domain on **443**
2. Host nginx serves the pre-rendered `index.html` from `$CREDENTIALS_WEBROOT` (default `/var/www/vpn`)
3. HTTP Basic Auth protects access using `/etc/nginx/htpasswd-vpn`
4. Certbot manages the TLS certificate for the domain
5. The page is **informational only** — static HTML with already-rendered credentials; no backend

### MTProxy flow

1. Telegram client connects to **2083/tcp**
2. Docker forwards to MTG's internal listener on `3128`
3. MTG uses a generated secret encoding an impersonated domain (Google), making traffic look like HTTPS
4. No separate certificate or domain required

### VLESS+Reality flow

1. VPN client connects to **8443/tcp**
2. Xray accepts VLESS with `xtls-rprx-vision` flow
3. Reality presents a real TLS handshake to the active cover domain (rotates every 2h)
4. Client requires: UUID, public key, short ID, SNI, `fp=chrome`
5. The VLESS URI is rendered into the credentials page (QR + copyable link)

### Shadowsocks 2022 flow

1. VPN client connects to **8388** (TCP or UDP)
2. Xray accepts Shadowsocks with `2022-blake3-aes-256-gcm` — a 32-byte base64 key
3. Client requires: server IP, port 8388, method, password
4. The SS URI (`ss://...`) is rendered into the credentials page (QR + copyable link)

### IKEv2/IPSec flow

1. IKE negotiation on **500/udp** (or **4500/udp** for NAT traversal)
2. `hwdsl2/ipsec-vpn-server` handles tunnel setup with EAP (username/password) auth
3. PSK (pre-shared key) provides an additional layer of authentication
4. Client PKI profile (`.mobileconfig` / `.sswan`) can be exported with `docker exec ipsec ikev2.sh --export-client client`
5. All IKEv2 parameters are shown on the credentials page for manual setup

## Configuration and secret lifecycle

### Version-controlled inputs

The repo stores templates and automation, not live secrets:

- shell scripts and templates
- docker-compose definition
- nginx configs and vhost template
- credentials page template
- documentation

### Generated artifacts

The live configuration is produced on the server by `generate-secrets.sh`:

| Artifact | Generated by | Purpose |
| --- | --- | --- |
| `.env` | `generate-secrets.sh` | Central variable store — all credentials for all protocols |
| `mtg/config.toml` | `generate-secrets.sh` | MTG runtime configuration |
| `xray/config.json` | `generate-secrets.sh` / `render-xray-config.sh` | Xray runtime (VLESS + SS inbounds) |
| `/var/www/vpn/index.html` | `setup-nginx.sh` / `render-credentials-page.sh` | Rendered credentials page |
| `/etc/nginx/htpasswd-vpn` | `setup-nginx.sh` | HTTP Basic Auth credential file |
| `ipsec/data/` | `ipsec` container on first start | IKEv2 PKI, CA cert, client profile |

These generated files are intentionally gitignored.

### `.env` variable groups

| Group | Variables |
| --- | --- |
| Server | `SERVER_IP` |
| MTProxy | `MTG_SECRET`, `MTG_PORT`, `MTG_LINK` |
| VLESS+Reality | `XRAY_UUID`, `XRAY_PRIVATE_KEY`, `XRAY_PUBLIC_KEY`, `XRAY_SHORT_ID`, `XRAY_SNI`, `XRAY_DEST`, `VLESS_URI` |
| Rotation | `XRAY_COVER_DOMAINS` (35-domain pool), `XRAY_ROTATE_HOURS` (default: 2) |
| Shadowsocks | `SS_METHOD`, `SS_PORT`, `SS_PASSWORD`, `SS_URI` |
| IKEv2 | `IKE_PSK`, `IKE_USER`, `IKE_PASSWORD` |
| Credentials page | `PAGE_USER`, `PAGE_PASSWORD`, `CREDENTIALS_DOMAIN`, `CREDENTIALS_WEBROOT` |

### `.env` rewrite invariant

`rotate-reality-cover.sh` rewrites `.env` atomically via `mktemp + chmod 600 + mv`. **Every variable must be explicitly listed in the heredoc** — any variable added to `generate-secrets.sh` that is not also in the rotation heredoc will be silently dropped on the next rotation.

## VLESS cover domain rotation

The rotation mechanism runs every 2 hours via `xray-rotate.timer`:

1. Loads `XRAY_COVER_DOMAINS` (comma-separated pool of 35 domains)
2. Shuffles candidates with `sort -R`
3. TLS-checks each candidate via `curl --max-time 5` (tries TLS 1.3 first, falls back for LibreSSL compat)
4. Picks the first reachable domain different from the current `XRAY_SNI`
5. If no candidate passes TLS check: **aborts** (does not silently fall back to old domain)
6. Atomically rewrites `.env`, re-renders `xray/config.json` and `index.html`, restarts `xray`

Shadowsocks and IKEv2 are not affected by rotation.

## Web layer architecture

### Technology profile

- **HTML + inline CSS + inline JavaScript** — no framework, no build step
- **server-side variable substitution** via `envsubst` (explicit variable list to avoid clobbering nginx vars)
- **nginx** for serving static content with HTTP Basic Auth
- **qrcodejs from cdnjs** for client-side QR code rendering

### Page structure

`web/index.html.template` renders a single credentials page with four protocol cards:

1. **MTProxy card** — `tg://` button, server/port/secret fields
2. **VLESS card** — QR code, VLESS URI, app links, manual fields (UUID, public key, short ID, SNI, port)
3. **Shadowsocks card** — QR code, SS URI, manual fields (server, port, method, password)
4. **IKEv2 card** — server, login, password, PSK, client profile export instructions

### envsubst scope

Both `render-credentials-page.sh` and `web/entrypoint.sh` use an explicit variable list:
```
${SERVER_IP}${MTG_PORT}${MTG_SECRET}${MTG_LINK}${XRAY_UUID}${XRAY_PUBLIC_KEY}
${XRAY_SHORT_ID}${XRAY_SNI}${VLESS_URI}${XRAY_ROTATION_MESSAGE}
${SS_URI}${SS_PORT}${SS_METHOD}${SS_PASSWORD}${IKE_PSK}${IKE_USER}${IKE_PASSWORD}
```
This explicit list prevents `envsubst` from clobbering nginx's own `$uri`, `$host`, etc.

Any new credential variable must be added to the envsubst list in **both** files.

## Provisioning and deployment workflow

### Standard setup sequence

1. Copy the repo to the target server (via `deploy.sh` or `rsync`)
2. Install Docker on the VPS
3. Run `generate-secrets.sh <SERVER_IP> [REALITY_COVER_DOMAIN] [CREDENTIALS_DOMAIN]`
4. Run `setup-nginx.sh` as root
5. Run `docker compose up -d`
6. (First time) `docker exec ipsec ikev2.sh --export-client client` to generate IKEv2 profiles

### Operational update path

- `deploy.sh` — syncs project files, re-renders configs, restarts containers
- `setup-nginx.sh` — must be re-run when the vhost template, rotation timer, or UFW rules change
- `docker compose up -d` — applies compose changes (new image tags, service additions)
- `render-xray-config.sh` — rebuilds only `xray/config.json` (e.g., after manual `.env` edits)

### Deployment assumptions

- Ubuntu/Debian-style package management (`apt-get`)
- Host nginx layout under `/etc/nginx/sites-available` and `/etc/nginx/sites-enabled`
- `ufw` available as the firewall
- Docker installed and running
- Operator can run host setup as root

## Security model

### Controls in place

- Live secrets excluded from git and from `deploy.sh` rsync
- `.env` permissions set to `600` (enforced on every rotation rewrite)
- Credentials page protected by HTTP Basic Auth
- Xray private key remains server-side only; only public key goes to clients
- MTProxy and Xray consume config files as read-only mounts
- TLS via Certbot for the credentials page
- VLESS+Reality — TLS impersonation; no fingerprint from a self-signed cert
- Shadowsocks 2022 — AEAD encryption with modern cipher
- IKEv2 — PKI-backed, `VPN_IKEV2_ONLY=yes` enforces IKEv2 (not older IPSec modes)

### Security boundaries

The credentials page aggregates all protocol secrets. Anyone with access can recover MTProxy secret, VLESS parameters, Shadowsocks password, and IKEv2 credentials. That makes it a high-value operational surface even though it is statically served.

### Known limitations

- Secrets are stored in plaintext in `.env` on the server
- No rate limiting or MFA around the credentials page beyond HTTP Basic Auth
- No backup/restore mechanism for generated credentials
- `ipsec` image is pinned to `latest` (no semver tags available for this image)

## Architectural strengths

1. **Simple operating model** — minimal moving parts, no app backend
2. **Clear protocol separation** — MTProxy (Telegram), VLESS+Reality (stealth VPN), Shadowsocks (broad compat), IKEv2 (native client)
3. **Cover domain diversity** — 35-domain rotation pool (20 international + 15 Russian) with TLS availability check prevents fingerprinting
4. **Low maintenance surface** — no build system, database, or application runtime to patch
5. **Good secret hygiene in git** — all generated files excluded from version control and rsync deploys
