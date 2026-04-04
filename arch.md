# Hogen VPN Architecture Report

## Executive summary

This repository is an infrastructure-first deployment bundle for a small self-hosted censorship-bypass stack. It combines:

1. **MTProxy** for Telegram-only traffic.
2. **VLESS + Reality (Xray)** for full-device VPN traffic.
3. **A password-protected static credentials page** served by host nginx over HTTPS.

There is **no traditional backend application** in this project: no API server, no database, no package-managed frontend, and no build pipeline. The repository is mostly shell automation, container runtime configuration, and a static HTML template rendered with environment variables during deployment.

## Repository structure

| Path | Role |
| --- | --- |
| `README.md` | High-level setup and deployment instructions. |
| `docker-compose.yml` | Starts the runtime containers for MTProxy and Xray. |
| `generate-secrets.sh` | One-time secret/config generator for `.env`, `mtg/config.toml`, and `xray/config.json`. |
| `setup-nginx.sh` | Host-level setup for the credentials page, HTTP basic auth, firewall rules, and Certbot integration. |
| `deploy.sh` | Rsync-based deployment script for syncing tracked files to the target server. |
| `.env.example` | Template for required runtime variables. |
| `setup.md` | Manual MTProxy server setup notes. |
| `vless-setup.md` | Manual VLESS + Reality setup notes. |
| `user-manual.md` | End-user connection instructions in Russian. |
| `web/index.html.template` | Static credentials page template rendered with `envsubst`. |
| `web/nginx-vhost.conf` | Host nginx vhost used in the standard deployment flow. |
| `web/nginx.conf` | Standalone nginx config for an optional containerized web mode. |
| `web/entrypoint.sh` | Entrypoint for the optional standalone web container mode. |

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
    E --> J[MTProxy container]
    F --> K[Xray container]

    L[Browser user] -->|HTTPS 443| I
    M[Telegram client] -->|TCP 2083| J
    N[VLESS client] -->|TCP 8443| K
```

## Runtime architecture

### 1. Host-level services

The standard deployment relies on the VPS host for the following:

- **nginx** as the HTTPS web server for the credentials page
- **Certbot** to provision and inject TLS configuration into the nginx vhost
- **ufw** to open the MTProxy and VLESS ports
- **filesystem storage** for generated secrets, rendered HTML, and the htpasswd file

The host-served credentials page is the normal deployment path described in `README.md` and implemented by `setup-nginx.sh`.

### 2. Containerized services

`docker-compose.yml` defines two long-running services:

| Service | Image | Host port | Internal role |
| --- | --- | --- | --- |
| `mtg` | `nineseconds/mtg:2` | `2083 -> 3128` | Telegram MTProxy endpoint with domain-fronting style secret generation |
| `xray` | `ghcr.io/xtls/xray-core:latest` | `8443 -> 8443` | VLESS + Reality inbound for full VPN traffic |

Both containers use:

- `restart: unless-stopped`
- read-only mounted config files from the host
- public upstream images rather than locally built images

### 3. Optional standalone web mode

The `web/nginx.conf` and `web/entrypoint.sh` files define an alternate way to serve the credentials page from a container. That mode is **not wired into `docker-compose.yml`** and is therefore an auxiliary deployment option, not the primary architecture path.

## Network and request flow

### Credentials page flow

1. A browser connects to the public domain on **443**.
2. Host nginx serves the rendered `index.html` from `/var/www/vpn`.
3. HTTP Basic Auth protects access using `/etc/nginx/htpasswd-vpn`.
4. Certbot modifies the nginx vhost to enable HTTPS and redirects.
5. The browser receives a static page containing already-rendered connection values.

This page is **informational only**. It does not proxy traffic, expose an API, or fetch secrets dynamically after load.

### MTProxy flow

1. Telegram clients connect to the server on **2083/tcp**.
2. Docker forwards that port to MTG's internal listener on `3128`.
3. MTG uses a generated secret that encodes an impersonated domain (`google.com` in the current script).
4. Clients use the generated Telegram link or manual server/port/secret fields shown on the credentials page.

### VLESS + Reality flow

1. VPN clients connect to **8443/tcp**.
2. Xray accepts **VLESS** connections with `xtls-rprx-vision`.
3. Reality is configured to impersonate `www.microsoft.com:443`.
4. Clients use:
   - server IP
   - UUID
   - public key
   - short ID
   - SNI (`www.microsoft.com`)
   - fingerprint `chrome`
5. The full connection URI is rendered into the credentials page and can also be represented as a QR code.

## Configuration and secret lifecycle

### Version-controlled inputs

The repo stores templates and automation, not live secrets:

- shell scripts
- docker-compose definition
- nginx configs
- the credentials page template
- documentation

### Generated artifacts

The live configuration is produced on the server by `generate-secrets.sh`:

| Artifact | Generated by | Purpose |
| --- | --- | --- |
| `.env` | `generate-secrets.sh` | Central variable store for server IP, MTProxy values, VLESS values, and page credentials |
| `mtg/config.toml` | `generate-secrets.sh` | MTG runtime configuration |
| `xray/config.json` | `generate-secrets.sh` | Xray runtime configuration |
| `web/index.html` or `/var/www/vpn/index.html` | `setup-nginx.sh` or `web/entrypoint.sh` | Rendered credentials page |
| `/etc/nginx/htpasswd-vpn` | `setup-nginx.sh` | Basic-auth credential file |

These generated files are intentionally ignored by git:

- `.env`
- `mtg/config.toml`
- `xray/config.json`
- `web/index.html`
- `web/.htpasswd`

### Secret generation details

`generate-secrets.sh` currently creates:

- an MTProxy secret using the MTG image
- a UUID for VLESS clients
- an X25519 keypair using Xray
- a short ID using OpenSSL
- a random page password for HTTP Basic Auth

It also derives:

- a Telegram deep link
- a VLESS URI suitable for copy/paste or QR import

## Web layer architecture

The `web/` subtree is a minimal static frontend with **no framework and no build step**.

### Technology profile

- **HTML + inline CSS + inline JavaScript**
- **server-side variable substitution** via `envsubst`
- **nginx** for serving static content
- **qrcodejs from cdnjs** for client-side QR rendering

### Page structure

`web/index.html.template` renders a single credentials page with two sections:

1. **Telegram MTProxy card**
   - direct `tg://` connection button
   - server
   - port
   - secret
   - Telegram proxy link

2. **VLESS card**
   - QR code
   - copyable VLESS URI
   - app links for Android, iPhone, Windows, and macOS
   - manual fields for address, port, UUID, security mode, SNI, public key, and short ID

### Client-side behavior

The browser-side JavaScript only does two things:

- generate a QR code for the VLESS URI
- copy values to the clipboard with brief UI feedback

There is **no backend session**, **no API**, and **no persistence**.

## Provisioning and deployment workflow

### Standard setup sequence

The intended lifecycle is:

1. Copy the repo to the target server.
2. Install Docker on the VPS.
3. Run `generate-secrets.sh <SERVER_IP>`.
4. Run `setup-nginx.sh` as root.
5. Start the containers with `docker compose up -d`.

### Operational update path

For subsequent changes:

- `deploy.sh` syncs tracked project files to the server
- `setup-nginx.sh` must be re-run when the credentials page template changes
- `docker compose up -d` must be re-run when container config changes

### Deployment assumptions

The automation assumes:

- Ubuntu/Debian-style package management (`apt-get`)
- host nginx layout under `/etc/nginx/sites-available` and `/etc/nginx/sites-enabled`
- `ufw` is available and used as the firewall
- Docker is installed and working
- the operator can run host setup as root

## Service-specific configuration

### MTProxy

`mtg/config.toml` is generated with a minimal shape:

```toml
secret = "..."
bind-to = "0.0.0.0:3128"
```

Architecturally, MTProxy is isolated and simple:

- one inbound listener
- no extra middleware
- one host port exposure
- one secret-driven connection scheme

### Xray / VLESS + Reality

`xray/config.json` configures:

- a single inbound on port `8443`
- protocol `vless`
- one client UUID
- `xtls-rprx-vision` flow
- `reality` security
- a single Reality destination and SNI target
- `freedom` and `blackhole` outbounds

This is a compact single-user/single-endpoint layout rather than a multi-tenant gateway.

## Security model

### Positive controls already present

- live secrets are excluded from git
- deployment sync excludes generated secret files
- host nginx credentials page is basic-auth protected
- Xray private key remains server-side only
- MTProxy and Xray consume generated config files as read-only mounts
- TLS is used for the credentials page through Certbot-managed nginx
- obfuscation is applied at both transport layers:
  - MTProxy secret-based fronting style
  - Reality-based TLS impersonation for VLESS

### Security boundaries

The credentials page is the main aggregation point for secrets. Anyone with access to that page can recover:

- the MTProxy secret
- the VLESS URI
- the VLESS public parameters needed by clients

That makes the page a high-value operational surface even though it is technically static.

### Important limitations

- Secrets are stored in plaintext in `.env` on the server.
- There is no secret rotation workflow in the repo.
- There is no auditing, rate limiting, or multi-factor access around the credentials page.
- There is no backup/restore mechanism for generated credentials.

## Architectural strengths

1. **Simple operating model**: minimal moving parts and no app backend.
2. **Clear separation of concerns**: host nginx serves the portal; Docker runs the transports.
3. **Low maintenance surface**: no build system, database, or application runtime to patch.
4. **Easy regeneration path**: one script creates the core runtime configs.
5. **Good secret hygiene in git**: generated files are excluded from version control and from rsync deploys.

## Observed inconsistencies and risks

### 1. Documentation and script mismatch for `generate-secrets.sh`

`README.md` shows usage like:

```bash
./generate-secrets.sh your.domain.com
```

But the script actually requires:

```bash
./generate-secrets.sh <SERVER_IP>
```

The generated links and URIs are IP-based, not domain-based.

### 2. Hardcoded deployment target details

Some operational settings are hardcoded instead of parameterized:

- `setup-nginx.sh` hardcodes `DOMAIN="universal.ramilkarimov.me"`
- `deploy.sh` hardcodes:
  - SSH host
  - remote directory
  - SSH key path

That makes the repo portable only after manual editing.

### 3. `.env.example` is out of sync with the scripts

Current mismatches:

- `.env.example` includes `PAGE_PORT`, which is not used in the main deployment path
- `.env.example` does **not** include `MTG_PORT`, which is generated and used by the scripts

This weakens the file's value as a canonical environment contract.

### 4. Optional standalone web mode appears incomplete

`web/entrypoint.sh` performs `envsubst`, but its explicit variable list omits `MTG_PORT` even though `index.html.template` uses it. In the standalone web-container path, the MTProxy port placeholder would therefore not be rendered correctly unless the script is updated.

### 5. No health checks or observability

There are no:

- Docker healthchecks
- metrics
- uptime checks
- automated log collection
- CI validation for generated config correctness

This is acceptable for a small personal deployment, but it limits operational maturity.

### 6. Single-node architecture

The current design assumes one VPS and one instance of each service. There is no:

- failover
- horizontal scaling
- multi-user isolation model
- backup control plane

### 7. External dependency for QR generation

The credentials page depends on a CDN-hosted QR library. If that asset is blocked or unavailable, the page still loads, but QR generation falls back to a text placeholder.

## Current architectural verdict

This project is best understood as a **deployment kit for a single-server private proxy/VPN setup**, not as an application platform. Its architecture is intentionally compact:

- **host nginx** for the protected portal
- **Docker Compose** for the transport services
- **shell scripts** for provisioning and regeneration
- **static HTML** for user-facing credential distribution

That simplicity is the project's main strength. The main weaknesses are not in runtime complexity but in **parameterization, consistency between docs and scripts, and operational hardening**.
