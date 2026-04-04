# VLESS+Reality VPN — Server Setup (vdsina.ru)

VLESS+Reality routes **all traffic** (not just Telegram) through your VPS, disguising it as HTTPS to a real website. No certificates, no domain name required.

## Requirements

- Same VPS as MTProxy (or a separate one)
- Port **8443** free (port 443 is already used by mtg)
- Docker installed

---

## 1. Open Port 8443

```bash
ufw allow 8443/tcp
ufw status
```

Also check vdsina's network-level firewall in the control panel and open 8443 there too.

---

## 2. Generate Credentials

### UUID (user password)

```bash
cat /proc/sys/kernel/random/uuid
```

Save the output. Example: `550e8400-e29b-41d4-a716-446655440000`

### Reality keypair

```bash
docker run --rm ghcr.io/xtls/xray-core xray x25519
```

Output:
```
Private key: 2KZ4uouMKgI8nR-LDJNP1_MHisCJOmKGj9jUjZLncVU
Public key:  Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw
```

- **Private key** — server only, never share
- **Public key** — goes into every client config

### ShortId

```bash
openssl rand -hex 8
# example: 6ba85179e30d4fc2
```

---

## 3. Choose a `dest` Domain

Reality impersonates a real website. When anyone connects to your server without your credentials, they see a legitimate TLS handshake to this domain.

Requirements: must support TLSv1.3 and HTTP/2, no redirects.

Good choices:
- `www.microsoft.com:443`
- `www.cloudflare.com:443`
- `github.com:443`
- `www.bing.com:443`
- `www.office.com:443`

Verify from your VPS:

```bash
curl -vI --http2 https://www.microsoft.com 2>&1 | grep -E "TLSv1.3|HTTP/2"
```

You should see both `TLSv1.3` and `HTTP/2` in the output.

If you are using this repository's automation, `./generate-secrets.sh <SERVER_IP> [REALITY_COVER_DOMAIN]` will use the optional second argument as the initial cover domain. If you omit it, the script randomly picks one from the curated list above so different deployments do not all reuse the same default target.

The automated setup can also rotate the active cover domain every few hours. Because REALITY ties `serverNames` to the active `dest`, an older imported profile may stop working after rotation; users should reopen the credentials page and import the fresh link or QR code. If you want stable long-lived profiles instead, set `XRAY_ROTATE_HOURS=0` before rerunning `./setup-nginx.sh`.

---

## 4. Create Config

```bash
mkdir -p /opt/xray/config
```

Create `/opt/xray/config/config.json` — replace the four placeholder values:

```json
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": 8443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "YOUR_UUID",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "www.microsoft.com:443",
                    "serverNames": ["www.microsoft.com"],
                    "privateKey": "YOUR_PRIVATE_KEY",
                    "shortIds": ["YOUR_SHORT_ID"],
                    "maxTimeDiff": 60000
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
            }
        }
    ],
    "outbounds": [
        { "protocol": "freedom", "tag": "direct" },
        { "protocol": "blackhole", "tag": "block" }
    ]
}
```

---

## 5. Run with Docker Compose

Create `/opt/xray/docker-compose.yml`:

```yaml
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./config:/etc/xray
    command: xray run -c /etc/xray/config.json
```

Start it:

```bash
cd /opt/xray
docker compose up -d
docker compose logs -f
```

Look for `Configuration OK` in the logs. No errors = running.

---

## 6. Enable NTP (important)

Reality validates timestamps. If the server clock drifts, clients will silently fail to connect.

```bash
timedatectl set-ntp true
timedatectl status   # must show: NTP synchronized: yes
```

---

## 7. Build the Client Share Link

Generate a VLESS URI to share with users (or scan as QR):

```
vless://YOUR_UUID@YOUR_VPS_IP:8443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=YOUR_PUBLIC_KEY&sid=YOUR_SHORT_ID&type=tcp#MyVPN
```

Replace `YOUR_UUID`, `YOUR_VPS_IP`, `YOUR_PUBLIC_KEY`, `YOUR_SHORT_ID`.

This link can be imported directly into v2rayNG (Android), v2rayN (Windows), Hiddify, Shadowrocket (iOS), and most other clients.

To generate a QR code from the terminal:

```bash
apt install -y qrencode
qrencode -t ANSI "vless://YOUR_UUID@..."
```

---

## Maintenance

| Task | Command |
|---|---|
| Check status | `docker compose -f /opt/xray/docker-compose.yml ps` |
| View logs | `docker compose -f /opt/xray/docker-compose.yml logs` |
| Restart | `docker restart xray` |
| Update image | `docker pull ghcr.io/xtls/xray-core:latest && docker restart xray` |

---

## Troubleshooting

**Clients connect but traffic doesn't flow:**
- Confirm NTP is synced
- Confirm `flow=xtls-rprx-vision` is set on both server and client

**Container won't start:**
```bash
docker compose logs xray
```
Usually a JSON syntax error in `config.json` or a wrong field value.

**Port 8443 unreachable:**
```bash
ufw status          # check OS firewall
ss -tlnp | grep 8443  # confirm xray is actually listening
```
Also check vdsina's control panel — there's a separate network firewall.

**`serverNames` mismatch:**
Verify the dest domain's certificate covers the name you put in `serverNames`:
```bash
echo | openssl s_client -connect www.microsoft.com:443 2>/dev/null \
  | openssl x509 -noout -text | grep "DNS:"
```
