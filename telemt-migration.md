# MTProxy Migration: `nineseconds/mtg` → `telemt`

## Overview

This document is a step-by-step migration guide for replacing the `nineseconds/mtg:2` container
in this repository with [`telemt/telemt`](https://github.com/telemt/telemt) (v3.3.39+, April 2026).
It covers **pros and cons, architecture changes, secret conversion, updated scripts, and rollback**.

The migration is optional — `mtg` still works — but `telemt` fixes several active
vulnerabilities that affect reliability in Russia specifically (April 2026 context).

---

## Pros and Cons

### Reasons to Migrate (telemt advantages)

| Issue | mtg behaviour | telemt behaviour |
|---|---|---|
| **Active-probe SNI relay bug** (issue #458) | Relays probe to *configured* cover domain regardless of probe SNI → mismatch detected | Correct transparent TCP splice: relays to *the SNI the probe sent* → indistinguishable |
| **Middle-proxy support** | Not implemented; direct DC routing only | `use_middle_proxy = true` routes through Telegram's middle-proxy network |
| **ISP-level DC filtering** | Cannot bypass; needs external SOCKS5 chain | Built-in middle-proxy bypasses DC-IP filtering transparently |
| **TLS ServerHello noise** | Fixed 2500–4700 byte range regardless of cover domain | `tls_emulation = true` fetches real cert chain size and uses calibrated noise |
| **Multiple cover domains** | One domain at a time; rotation requires container restart | `tls_domains = [...]` supports many domains simultaneously; each gets its own link |
| **Prometheus metrics** | Not built-in | Native Prometheus endpoint at `:9090/metrics` |
| **Management API** | None | REST API at `:9091` for live user management and link generation |
| **Config hot-reload** | Requires container restart | Users section reloads without restart; domain changes auto-reload |
| **Port 443** | Fixed at host `2083` in this repo | Default `server.port = 443`; supports mobile Russian network whitelists |
| **Runtime language** | Go | Rust (lower memory, no GC pauses) |

### Reasons to Be Cautious (telemt risks / trade-offs)

| Concern | Detail |
|---|---|
| **Younger project** | mtg has been stable since ~2020; telemt is newer (2025). More config surface area to get wrong. |
| **Middle-proxy adds latency** | Routing via Telegram's middle-proxy adds ~30–80 ms vs. direct mode. Disable with `use_middle_proxy = false` if DC filtering is not a problem for your hoster. |
| **Middle-proxy requires Telegram connectivity** | The VPS must reach `core.telegram.org` for the proxy-secret download. Firewalls blocking Telegram from the VPS affect startup. |
| **User links change** | Changing the listening port from `2083` to `443` changes all existing Telegram proxy links. Users must re-import new links. |
| **Different config schema** | All setup/rotation scripts need updates. Run carefully; rollback is described in §7. |
| **`tls_front_dir` cache** | `tls_emulation = true` fetches real TLS metadata and caches it. Requires a writable path inside the container (tmpfs in the Docker compose config below handles this). |
| **No official Docker Hub image** | Image is on GitHub Container Registry: `ghcr.io/telemt/telemt:latest`. Pull may be slower on first run. |

---

## How the Secret Format Changes

This is the most important thing to understand before starting.

### mtg secret format

`mtg generate-secret <domain>` produces a compound string:

```
ee  <32-hex raw key>  <hex-encoded domain>
^   ^                 ^
│   16 raw bytes      domain bytes encoded as hex
"FakeTLS" prefix
```

Example:
```
ee b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6 706574726f766963682e7275
   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^^^^^^^^^
   32 hex chars = raw key           hex("petrovich.ru")
```

The domain is **baked into the secret**. Changing the domain requires generating a new secret
and redistributing links to all users.

### telemt secret format

telemt separates these two concerns:

```toml
[censorship]
tls_domain = "petrovich.ru"   # domain lives here

[access.users]
alice = "b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6"   # just the 32-hex raw key
```

telemt's management API constructs the full `ee<key><domain>` Telegram link for you.

### Extracting the raw key from an existing mtg secret

```bash
MTG_SECRET="ee b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6706574726f766963682e7275"
# Remove spaces from example above; real value has no spaces

# Strip the 2-char "ee" prefix, take the next 32 hex chars
RAW_KEY="${MTG_SECRET:2:32}"
echo "$RAW_KEY"   # b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6

# Decode the remaining hex to recover the cover domain
DOMAIN_HEX="${MTG_SECRET:34}"
DOMAIN=$(python3 -c "import binascii,sys; print(binascii.unhexlify(sys.argv[1]).decode())" "$DOMAIN_HEX")
echo "$DOMAIN"    # petrovich.ru
```

**Key result**: if you use the same `RAW_KEY` in `[access.users]` and the same `DOMAIN`
in `[censorship] tls_domain`, telemt generates an **identical** `tg://proxy?...&secret=ee...`
link. Users do not need to re-import their proxy settings — **unless** you also change the port.

---

## Architecture Change Summary

| Component | Before (mtg) | After (telemt) |
|---|---|---|
| Container image | `nineseconds/mtg:2` | `ghcr.io/telemt/telemt:latest` |
| Config file | `mtg/config.toml` (2 lines) | `telemt/config.toml` (rich TOML) |
| Listening port (host) | `2083` | `443` (recommended) |
| Container port | `3128` | `443` |
| Secret generation | `docker run nineseconds/mtg:2 generate-secret <domain>` | `openssl rand -hex 16` |
| Link generation | Constructed manually from secret+domain | telemt API: `GET :9091/v1/users` |
| Cover domain rotation | Restart container with new `ee` secret | Reload config or use `tls_domains` list |
| Health check | `mtg access /config/config.toml` | TCP port check or `GET :9091/v1/status` |

---

## Step-by-Step Migration

### Step 0 — Prerequisites and backup

```bash
cd /path/to/hogen-vpn

# 1. Backup current state
cp .env .env.backup-before-telemt
cp mtg/config.toml mtg/config.toml.backup

# 2. Note the current port (used in existing user links)
grep MTG_PORT .env          # → 2083
grep MTG_SECRET .env        # → ee...
grep MTG_COVER_DOMAIN .env  # → e.g. www.vk.com
```

### Step 1 — Extract raw key and cover domain from mtg secret

```bash
# Read the existing mtg secret
MTG_SECRET=$(grep '^MTG_SECRET=' .env | cut -d= -f2- | tr -d '"')

# Extract the 32-hex raw key (bytes 3–34 of the ee... string)
RAW_KEY="${MTG_SECRET:2:32}"

# Recover the domain from the remaining hex
DOMAIN_HEX="${MTG_SECRET:34}"
COVER_DOMAIN=$(python3 -c \
  "import binascii,sys; print(binascii.unhexlify(sys.argv[1]).decode())" \
  "$DOMAIN_HEX")

echo "RAW_KEY:      $RAW_KEY"
echo "COVER_DOMAIN: $COVER_DOMAIN"
```

Save these values; you will need them in Step 3.

### Step 2 — Create the telemt config directory and file

```bash
mkdir -p telemt
chmod 700 telemt
```

Create `telemt/config.toml` (replace placeholders with values from Step 1):

```toml
# telemt/config.toml
[general]
use_middle_proxy = true   # bypass ISP-level Telegram DC filtering
log_level = "normal"

[general.modes]
classic = false
secure  = false
tls     = true            # FakeTLS (ee) mode only

[general.links]
show = "none"             # retrieve links via management API (GET :9091/v1/users)

[server]
port = 443                # HTTPS port — collateral-damage protection on Russian mobile

[server.api]
enabled   = true
listen    = "0.0.0.0:9091"
# Docker NAT rewrites source to bridge gateway (~172.17.0.1); loopback-only blocks host.
whitelist = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain   = "COVER_DOMAIN_HERE"   # e.g. www.vk.com
tls_domains  = [                      # all 35 pool domains for simultaneous links
  "www.microsoft.com", "www.cloudflare.com", "github.com",
  "www.bing.com", "www.apple.com", "www.google.com",
  "www.samsung.com", "www.nvidia.com", "www.intel.com",
  "www.oracle.com", "www.ibm.com", "learn.microsoft.com",
  "www.lenovo.com", "www.amd.com", "www.hp.com",
  "www.cisco.com", "www.jetbrains.com", "www.aliexpress.com",
  "www.yahoo.com", "www.docker.com",
  "www.yandex.ru", "mail.ru", "www.vk.com",
  "www.ozon.ru", "www.wildberries.ru", "www.sberbank.ru",
  "www.tinkoff.ru", "www.gosuslugi.ru", "www.avito.ru",
  "habr.com", "www.kaspersky.ru", "www.dns-shop.ru",
  "www.mos.ru", "www.rt.com", "www.gazprom.ru"
]
unknown_sni_action = "mask"  # forward unknown SNI probes to real mask host
mask               = true
tls_emulation      = true    # calibrate ServerHello noise to real cert chain size
tls_front_dir      = "/run/tlsfront"   # writable tmpfs (see docker-compose.yml: tmpfs /run)

[access.users]
default = "RAW_KEY_HERE"   # 32-hex chars extracted in Step 1

[access]
replay_check_len  = 65536
replay_window_secs = 120
```

```bash
chmod 600 telemt/config.toml
```

### Step 3 — Update `docker-compose.yml`

Replace the `mtg` service block with `telemt`:

```yaml
  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "443:443"
      - "127.0.0.1:9091:9091"
    working_dir: /etc/telemt
    volumes:
      - ./telemt/config.toml:/etc/telemt/config.toml:ro
    tmpfs:
      - /run:rw,mode=0755,size=8m   # tls_front_dir cache (/run/tlsfront)
      # Note: do NOT use /etc/telemt as tmpfs — it would shadow the config bind-mount above.
    environment:
      RUST_LOG: "info"
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - NET_ADMIN
    read_only: true
    ulimits:
      nofile:
        soft: 65536
        hard: 262144
    healthcheck:
      test: ["CMD-SHELL", "ss -tlnp | grep -q ':443 '"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s
```

> **Note**: Keep the old `mtg` block commented out until you verify telemt is working.
> You cannot have both services binding port 443/2083 at the same time.

### Step 4 — Stop mtg, start telemt

```bash
# Stop only the mtg container (leave other services running)
docker compose stop mtg
docker compose rm -f mtg

# Pull telemt image
docker compose pull telemt

# Start telemt
docker compose up -d telemt

# Tail logs — look for "listening on :443" and printed tg:// links
docker compose logs -f telemt
```

Expected startup output:
```
INFO  telemt::server > listening on 0.0.0.0:443
INFO  telemt::me     > middle-proxy connected to DC2
INFO  telemt::links  > [default] tls: tg://proxy?server=...&port=443&secret=ee...
```

### Step 5 — Retrieve the new proxy link

```bash
# Get all user links from the management API
curl -s http://127.0.0.1:9091/v1/users | \
  python3 -m json.tool | grep -A3 '"tls"'
```

Or more directly:

```bash
curl -s http://127.0.0.1:9091/v1/users | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
for user in data.get('data', []):
    print(f\"[{user['username']}]\")
    for link in user.get('links', {}).get('tls', []):
        print(f'  {link}')
"
```

**If the port changed (2083 → 443)**: the link will be different from the existing one.
Update `MTG_LINK` in `.env` and re-run `render-credentials-page.sh`.

**If you kept the same raw key and domain AND did not change the port**:
the `secret=ee...` portion in the link will be identical to the old one.

### Step 6 — Update `.env`

```bash
# Update MTG_PORT from 2083 to 443
sed -i 's/^MTG_PORT=2083/MTG_PORT=443/' .env

# Retrieve the new link from the telemt API and update MTG_LINK
NEW_LINK=$(curl -s http://127.0.0.1:9091/v1/users | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data'][0]['links']['tls'][0])")
# Update .env
grep -v '^MTG_LINK=' .env > .env.tmp && echo "MTG_LINK=\"${NEW_LINK}\"" >> .env.tmp && mv .env.tmp .env
chmod 600 .env
```

### Step 7 — Re-render the credentials page

```bash
./render-credentials-page.sh "${CREDENTIALS_WEBROOT:-/var/www/vpn}"
```

Verify the MTProxy link on the credentials page points to port 443.

### Step 8 — Update `check.sh`

In `check.sh`, update the two mtg references:

```bash
# Before:
MTG_TCP=$(check_tcp 2083)
MTG_CTR=$(check_service mtg)

# After:
MTG_TCP=$(check_tcp 443)
MTG_CTR=$(check_service telemt)
```

And in the HTML/JSON output sections:
```bash
# Before:
_tbody+="$(_row 'MTProxy (Telegram)'  'tcp:2083'       "$MTG_TCP")"$'\n'
_json_svc="\"mtproxy\": { \"tcp_2083\": \"${MTG_TCP}\",  \"container\": \"${MTG_CTR}\"  }"

# After:
_tbody+="$(_row 'MTProxy (Telegram)'  'tcp:443'        "$MTG_TCP")"$'\n'
_json_svc="\"mtproxy\": { \"tcp_443\": \"${MTG_TCP}\",   \"container\": \"${MTG_CTR}\"  }"
```

### Step 9 — Update cover-domain rotation

The `rotate-mtg-cover.sh` script uses `docker run nineseconds/mtg:2 generate-secret` and
restarts the container. With telemt this needs to change.

**Option A (recommended): No rotation needed**

Because `telemt/config.toml` already lists all 35 domains in `tls_domains`, telemt
generates **35 simultaneous links** — one per domain. The user can use any of them.
There is nothing to rotate. Disable the rotation timer:

```bash
systemctl disable --now mtg-rotate.timer 2>/dev/null || true
```

**Option B: Rotate `tls_domain` on a schedule**

Create `/etc/systemd/system/telemt-rotate.service`:

```ini
[Unit]
Description=Telemt cover-domain rotation
After=docker.service

[Service]
Type=oneshot
ExecStart=/path/to/hogen-vpn/rotate-telemt-cover.sh
```

Create `/etc/systemd/system/telemt-rotate.timer`:

```ini
[Unit]
Description=Rotate telemt cover domain every 2 hours

[Timer]
OnBootSec=5min
OnUnitActiveSec=120min
RandomizedDelaySec=10min

[Install]
WantedBy=timers.target
```

Create `rotate-telemt-cover.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/cover-domains.sh"

[[ -f "${SCRIPT_DIR}/.env" ]] || { log_error ".env not found"; exit 1; }
set -a; source "${SCRIPT_DIR}/.env"; set +a

CURRENT="${MTG_COVER_DOMAIN:-}"
CANDIDATES=()
for D in "${COVER_DOMAINS[@]}"; do
  [[ -n "$D" && "$D" != "$CURRENT" ]] && CANDIDATES+=("$D")
done
NEXT="${CANDIDATES[$RANDOM % ${#CANDIDATES[@]}]}"

# Hot-patch tls_domain in telemt config and send a reload signal
CONFIG="${SCRIPT_DIR}/telemt/config.toml"
sed -i "s|^tls_domain *= *\"[^\"]*\"|tls_domain = \"${NEXT}\"|" "$CONFIG"

# telemt reloads config on SIGHUP (users section) or on restart
docker compose -f "${SCRIPT_DIR}/docker-compose.yml" restart telemt >/dev/null

# Fetch new link from API
NEW_LINK=$(curl -s http://127.0.0.1:9091/v1/users | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data'][0]['links']['tls'][0])" 2>/dev/null)
[[ -n "$NEW_LINK" ]] || { log_error "Could not fetch new link from telemt API"; exit 1; }

# Update .env
MTG_COVER_DOMAIN="$NEXT"
MTG_LINK="$NEW_LINK"
grep -v -E '^(MTG_COVER_DOMAIN|MTG_LINK)=' "${SCRIPT_DIR}/.env" > /tmp/.env.new
echo "MTG_COVER_DOMAIN=${NEXT}" >> /tmp/.env.new
echo "MTG_LINK=\"${NEW_LINK}\""  >> /tmp/.env.new
chmod 600 /tmp/.env.new
mv /tmp/.env.new "${SCRIPT_DIR}/.env"

"${SCRIPT_DIR}/render-credentials-page.sh" "${CREDENTIALS_WEBROOT:-/var/www/vpn}"
date '+%Y-%m-%d %H:%M %Z' > "${SCRIPT_DIR}/.last_mtg_rotation"
log_ok "Telemt cover domain: ${CURRENT} → ${NEXT}"
```

```bash
chmod +x rotate-telemt-cover.sh
systemctl daemon-reload
systemctl enable --now telemt-rotate.timer
```

---

## nginx Conflict: Port 443

If nginx is already listening on port 443 on the host, you cannot also bind Docker to `443:443`.
You have two options:

### Option A — nginx SNI multiplexing (recommended)

Use `stream` module in nginx to route by SNI: MTProxy traffic (no recognisable HTTP) goes to
telemt on an internal port; HTTPS traffic goes to nginx's normal HTTP server.

In `/etc/nginx/nginx.conf` (top level, outside `http {}`):

```nginx
stream {
    map $ssl_preread_server_name $backend {
        default              127.0.0.1:9443;    # → nginx HTTPS
        ~.                   127.0.0.1:9444;    # catch-all SNI → telemt on internal port
        # or use a more specific rule to route known cover domains to telemt
    }
    server {
        listen      443;
        proxy_pass  $backend;
        ssl_preread on;
    }
}
```

Then bind telemt to an internal port instead:

```yaml
# docker-compose.yml telemt service
ports:
  - "127.0.0.1:9444:443"
```

### Option B — Use a different port with port-forwarding

Keep telemt on host port `8443` but advertise port `443` in the link by setting
`public_port = 443` in `[general.links]` and adding a host firewall DNAT rule:

```bash
iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443
```

### Option C — Move nginx to port 8080 / use separate IP

If this server only serves the VPN credentials page, consider moving nginx to port 80/8080
and letting telemt own port 443 entirely.

---

## Verification Checklist

```bash
# 1. Container is healthy
docker compose ps telemt

# 2. Port is listening
ss -tlnp | grep ':443 '

# 3. TLS handshake looks like the cover domain (requires openssl)
SERVER_IP=$(grep '^SERVER_IP=' .env | cut -d= -f2)
echo | openssl s_client -connect "${SERVER_IP}:443" \
  -servername "$(grep '^MTG_COVER_DOMAIN=' .env | cut -d= -f2)" \
  -quiet 2>&1 | head -5

# 4. Management API is reachable
curl -s http://127.0.0.1:9091/v1/users | python3 -m json.tool | head -20

# 5. Middle-proxy heartbeat is running (check logs)
docker compose logs telemt 2>&1 | grep -i 'middle\|DC\|connected' | tail -10

# 6. Run health check
./check.sh
```

---

## Rollback

If telemt is not working and you need to revert to mtg:

```bash
# Stop telemt
docker compose stop telemt
docker compose rm -f telemt

# Restore .env backup
cp .env.backup-before-telemt .env

# Restore mtg docker-compose service (re-enable the mtg block)
# Start mtg
docker compose up -d mtg

# Re-render credentials page
./render-credentials-page.sh "${CREDENTIALS_WEBROOT:-/var/www/vpn}"

# Re-enable old rotation timer if it was disabled
systemctl enable --now mtg-rotate.timer 2>/dev/null || true
```

---

## Post-Migration: Hardening Telemt Further

Once the basic migration is verified, consider these additional hardening steps:

### Register a real domain (highest impact)
Per `BEST_PRACTICES.md` (March 2026): set up a real domain that resolves via DNS to the VPS IP
and run a genuine webserver behind telemt's masking relay. This resolves the SNI/DNS mismatch
that TSPU passive analysis uses as its primary detection signal.

```toml
[censorship]
tls_domain = "proxy.yourdomain.com"  # A-record → this VPS IP
mask = true
mask_host = "proxy.yourdomain.com"   # or a separate upstream real webserver
```

### Force IPv4 for Telegram DC connections
Some hosters black-hole IPv6 to Telegram DCs:

```toml
[general]
prefer_ipv6 = false   # use IPv4 to Telegram DCs
```

### Enable Prometheus metrics

```toml
[server]
metrics_port      = 9090
metrics_whitelist = ["127.0.0.1/32"]
```

Add telemt to `monitoring/prometheus.yml`:
```yaml
  - job_name: telemt
    static_configs:
      - targets: ['telemt:9090']
```

### Sponsor channel (optional)

To show a sponsored channel in the proxy banner:

```toml
[general]
ad_tag = "your-32-hex-tag-from-MTProxybot"
use_middle_proxy = true   # required for ad_tag
```

---

## Reference: mtg vs telemt Config Mapping

| mtg `config.toml` | telemt `config.toml` equivalent |
|---|---|
| `secret = "ee<key><domain>"` | `[access.users] name = "<key>"` + `[censorship] tls_domain = "<domain>"` |
| `bind-to = "0.0.0.0:3128"` | `[server] port = 443` + `[[server.listeners]] ip = "0.0.0.0"` |
| _(no anti-replay config)_ | `[access] replay_check_len = 65536` |
| _(no domain fronting config)_ | `[censorship] mask = true` + `unknown_sni_action = "mask"` |
| _(no traffic shaping)_ | `[censorship] tls_emulation = true` |
| _(no metrics)_ | `[server] metrics_port = 9090` |
