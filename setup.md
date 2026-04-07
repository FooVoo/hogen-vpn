# Server Setup Guide

Complete walkthrough for deploying the full VPN stack on a fresh Ubuntu/Debian VPS.

## Requirements

- Ubuntu 22.04 LTS VPS (1 vCPU, 1 GB RAM minimum) outside the target region
- A domain name with an A record pointing to the server IP
- Root or sudo access
- Ports 80, 443, 2083, 8388, 8443 (TCP) and 500, 4500 (UDP) not blocked at the cloud/hosting firewall level

---

## 1. Order a VPS

Pick any provider with servers outside your target region: Hetzner, DigitalOcean, Vultr, vdsina, etc.

- OS: **Ubuntu 22.04 LTS**
- Location: outside your target region (Netherlands, Germany, Finland, etc.)
- Note the server **IP address** and **root password/SSH key**

After ordering, also open the firewall in the hosting control panel (if present — many providers have a separate network-level firewall in addition to `ufw`):

| Port(s) | Protocol | Service |
|---|---|---|
| 80, 443 | TCP | nginx / Let's Encrypt |
| 2083 | TCP | MTProxy |
| 8443 | TCP | VLESS + Reality |
| 8388 | TCP + UDP | Shadowsocks |
| 500 | UDP | IKEv2 |
| 4500 | UDP | IKEv2 NAT-T |
| **51820** | **UDP** | **WireGuard** |

---

## 2. Install Docker

```bash
ssh root@<SERVER_IP>

apt-get update && apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

Verify:

```bash
docker --version
docker compose version
```

---

## 3. Install nginx and Certbot

The credentials page runs on the host nginx. If nginx is not already installed:

```bash
apt-get install -y nginx certbot python3-certbot-nginx
```

Make sure port 80 and 443 are reachable — Certbot needs port 80 for the HTTP-01 challenge.

---

## 4. Copy the project to the server

On your **local machine**:

```bash
cp .deploy.env.example .deploy.env
# Edit .deploy.env: set DEPLOY_HOST=root@<SERVER_IP>
source .deploy.env && ./deploy.sh
```

Or manually:

```bash
rsync -az --exclude='.env' --exclude='mtg/' --exclude='xray/' --exclude='ipsec/' \
  ./ root@<SERVER_IP>:/opt/vpn/
```

---

## 5. Generate all secrets

On the **server**:

```bash
cd /opt/vpn
./generate-secrets.sh <SERVER_IP> [REALITY_COVER_DOMAIN] [CREDENTIALS_DOMAIN]
```

Examples:

```bash
# Minimal — auto-selects cover domain, credentials page domain set separately
./generate-secrets.sh 1.2.3.4

# Pin a specific cover domain
./generate-secrets.sh 1.2.3.4 www.microsoft.com

# Full — pin cover domain and set credentials page domain
./generate-secrets.sh 1.2.3.4 www.microsoft.com vpn.example.com
```

The script creates `.env`, `mtg/config.toml`, and `xray/config.json`.
**Write down the page login credentials** printed at the end — they are shown only once (though they are stored in `.env`).

If `CREDENTIALS_DOMAIN` was not passed as arg 3, add it to `.env` manually:

```bash
echo "CREDENTIALS_DOMAIN=vpn.example.com" >> /opt/vpn/.env
```

---

## 6. Set up nginx, SSL, firewall, and rotation timer

```bash
cd /opt/vpn
sudo ./setup-nginx.sh
```

This script:
1. Reads `CREDENTIALS_DOMAIN` from `.env`
2. Renders `web/nginx-vhost.conf.template` → nginx vhost
3. Obtains a Let's Encrypt certificate via Certbot
4. Creates `/etc/nginx/htpasswd-vpn` for Basic Auth
5. Renders the credentials page to `$CREDENTIALS_WEBROOT/index.html`
6. Allows SSH in UFW first (prevents lockout), then opens all required ports, then calls `ufw --force enable`
7. Installs `/etc/nginx/conf.d/vpn-ratelimit.conf` (5 req/min limit per IP on credentials page)
8. Installs and enables **fail2ban** with SSH + nginx-http-auth jails
9. Installs `vpn-reality-cover-rotate.timer` (fires every 30 minutes, 3-minute random jitter)
10. Installs `vpn-mtg-rotate.timer` (fires every 30 minutes, 3-minute random jitter)

After the script finishes, check nginx:

```bash
nginx -t && systemctl reload nginx
```

---

## 7. Start the containers

```bash
cd /opt/vpn
docker compose up -d
```

`setup-nginx.sh` already registered `hogen-vpn.service` to auto-start the stack on every boot. Verify it is enabled:

```bash
systemctl is-enabled hogen-vpn.service   # should print "enabled"
```

Check all three containers started:

```bash
docker compose ps
```

Expected output:

```
NAME          STATUS
mtg           Up (healthy)
xray          Up (healthy)
ipsec         Up (healthy)
wireguard     Up (healthy)
wgdashboard   Up (healthy)
cadvisor      Up (healthy)
prometheus    Up (healthy)
grafana       Up (healthy)
```

The `ipsec` container takes ~60 seconds to initialize on first run (generates PKI).

---

## 8. Apply IKEv2 reconnection fix (first run only)

This step patches the IKEv2 configuration so clients can reconnect after a drop
without requiring a container restart.

```bash
cd /opt/vpn
./setup-ipsec.sh
```

The script waits for `ipsec` to be healthy, then:
- Creates `ipsec/data/00-reconnect-fix.conf` — sets `uniqueids=replace` so
  a reconnecting client replaces its stale SA instead of conflicting with it
- Patches `ipsec/data/ikev2.conf` — tightens dead-peer detection from 30 s to
  15 s (with a 60 s timeout) to clear stale SAs faster after a client drops
- Restarts the `ipsec` container to load the new settings

Both files live in `ipsec/data/` (the persistent volume), so re-running the
script on a subsequent `docker compose up -d` is safe — it skips patches
already applied.

---

## 9. Export IKEv2 client profiles (first run only)

After `ipsec` is healthy:

```bash
docker compose exec ipsec ikev2.sh --export-client client
```

Files appear in `./ipsec/data/`:
- `client.mobileconfig` — iOS and macOS (double-tap to install, includes CA cert)
- `client.sswan` — Android strongSwan app

Distribute these to users via a secure channel (not email).

---

## 10. Verify each protocol

### MTProxy

```bash
# Check container is listening
ss -tlnp | grep 3128

# Confirm health
docker inspect --format='{{.State.Health.Status}}' $(docker compose ps -q mtg)
```

Test from Telegram: open the `tg://proxy?...` link shown on the credentials page.

### VLESS+Reality

```bash
ss -tlnp | grep 8443
docker inspect --format='{{.State.Health.Status}}' $(docker compose ps -q xray)
```

Test from a client: import the VLESS URI or QR from the credentials page.

```bash
# Verify NTP is synced (Reality requires timestamp accuracy)
timedatectl status | grep "NTP synchronized"
```

### Shadowsocks

```bash
ss -tlnp | grep 8388
ss -ulnp | grep 8388
```

Import the `ss://` URI from the credentials page into v2rayNG or Shadowrocket.

### IKEv2

```bash
docker compose exec ipsec ipsec status
```

Connect from iOS: Settings → General → VPN & Device Management → VPN → Add VPN Configuration → IKEv2.
Use the server, username, password, and PSK shown on the credentials page.

### WireGuard

```bash
# Verify wg0 interface is up and listening
docker compose exec wireguard wg show

# Check the container is healthy
docker inspect --format='{{.State.Health.Status}}' $(docker compose ps -q wireguard)
```

Expected output of `wg show`:
```
interface: wg0
  public key: <WG_SERVER_PUBLIC_KEY>
  private key: (hidden)
  listening port: 51820

peer: <WG_CLIENT_PUBLIC_KEY>
  preshared key: (hidden)
  allowed ips: 10.13.13.2/32
```

Download the `wg-client.conf` file from the credentials page and import it into the WireGuard app.

> **If handshake fails:** first verify that UDP 51820 is open in your **hosting provider's** network-level firewall (separate from UFW). Many providers (Hetzner, DigitalOcean, etc.) have a cloud firewall that must also be configured.

```bash
# Quick reachability check from outside the server
nc -zvu <SERVER_IP> 51820

# On the server — confirm UFW and Docker both expose the port
ufw status | grep 51820
ss -ulnp | grep 51820
```

### WGDashboard

```bash
# Check the container is healthy and port 10086 is bound
docker inspect --format='{{.State.Health.Status}}' $(docker compose ps -q wgdashboard)
docker compose exec wireguard ss -tlnp | grep 10086
```

Open `https://<DOMAIN>/wg-dash/` in a browser.
- **nginx layer**: user `admin`, password = `PAGE_TOKEN` (same as Grafana)
- **WGDashboard login**: user `admin`, password `admin` — change this on first login

### Grafana monitoring

```bash
docker compose ps cadvisor prometheus grafana
```

Open `https://<DOMAIN>/grafana/` — nginx auth: admin / PAGE_TOKEN, then Grafana: admin / PAGE_TOKEN.

Import the **Docker cAdvisor** dashboard from [grafana.com/dashboards/193](https://grafana.com/grafana/dashboards/193) to get per-container CPU, memory, network, and disk charts out of the box.

| Task | Command |
|---|---|
| View logs | `docker compose logs -f [mtg\|xray\|ipsec\|wireguard\|wgdashboard\|grafana\|prometheus]` |
| Restart a service | `docker compose restart xray` |
| Restart all | `docker compose restart` |
| Check auto-start service | `systemctl status hogen-vpn.service` |
| Force Xray rotation now | `sudo systemctl start vpn-reality-cover-rotate.service` |
| Force MTProxy rotation now | `sudo systemctl start vpn-mtg-rotate.service` |
| Check Xray rotation timer | `systemctl status vpn-reality-cover-rotate.timer` |
| Check MTProxy rotation timer | `systemctl status vpn-mtg-rotate.timer` |
| Backfill missing .env vars | `sudo ./migrate-env.sh && sudo ./setup-nginx.sh` |
| Regenerate credentials | `./generate-secrets.sh <IP> && sudo ./setup-nginx.sh && docker compose restart` |
| Update Xray config | `./render-xray-config.sh && docker compose restart xray` |
| Update WireGuard config (no rekey) | `./setup-wireguard.sh --update-config` |
| Regenerate WireGuard keys | `./setup-wireguard.sh --force` |
| Re-render nginx vhost | `sudo ./render-nginx-vhost.sh` |
| Re-render credentials page | `./render-credentials-page.sh` |

---

## Troubleshooting

**`ipsec` container not healthy after 2 minutes:**
```bash
docker compose logs ipsec
# First run generates PKI — takes ~60s. If still failing, check /lib/modules is mounted
```

**WireGuard handshake failing (client sends but gets no response):**

Most common cause: UDP 51820 is open in UFW but blocked by the **hosting provider's** network firewall.

```bash
# 1. Verify UFW has the rule
ufw status | grep 51820

# 2. Verify Docker is binding the port on the host
ss -ulnp | grep 51820

# 3. Verify wg0 is up inside the container
docker compose exec wireguard wg show

# 4. Check container logs for startup errors
docker compose logs wireguard
```

If `ss -ulnp | grep 51820` shows the port bound but the client still can't reach it, the block is at the cloud firewall — open UDP 51820 in the hosting control panel.

If `wg show` shows no peers or wrong keys, re-download the client config from the credentials page — keys may have been regenerated with `--force`.

**IKEv2 clients cannot reconnect after a drop (or reconnection requires a container restart):**

This is fixed by `setup-ipsec.sh` (step 8). If you skipped that step or are applying the fix to an existing deployment:
```bash
./setup-ipsec.sh
```
The two root causes and their fixes:
- `uniqueids=no` (hwdsl2 default) lets reconnecting clients create a second SA alongside the stale one; the IP pool then has a conflict and rejects the new connection. Fixed by `00-reconnect-fix.conf` (sets `uniqueids=replace`).
- Stale SAs linger for up to 2–3 minutes before DPD clears them. Fixed by patching `ikev2.conf` (`dpddelay=15`, `dpdtimeout=60`).

The improved healthcheck (`ss -ulnp | grep ':4500'`) also detects when pluto's socket is stuck so Docker auto-restarts the container without manual intervention.


**Xray won't start:**
```bash
docker compose logs xray
# Usually a JSON syntax error — run ./render-xray-config.sh to regenerate
```

**VLESS clients connect but traffic doesn't flow:**
```bash
timedatectl status   # clock must be NTP-synced
```

**Port unreachable from outside:**
```bash
ufw status          # check OS firewall
# Also check the hosting provider's network-level firewall
```

**Certbot fails — "port 80 connection refused":**
```bash
# nginx must be running and port 80 must reach the server
systemctl status nginx
ufw allow 80/tcp
```

**`setup-nginx.sh` fails: "CREDENTIALS_DOMAIN not set":**
```bash
# Add to .env:
echo "CREDENTIALS_DOMAIN=vpn.example.com" >> .env
```
