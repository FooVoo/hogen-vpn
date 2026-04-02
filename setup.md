# Telegram MTProxy — Server Setup (vdsina.ru)

## Requirements

- VPS on [vdsina.com](https://vdsina.com) — any Linux plan works (1 CPU / 512MB RAM is enough)
- OS: Ubuntu 22.04 LTS (recommended)
- Open ports: **443** (TCP inbound)
- Docker installed

---

## 1. Order a VPS on vdsina.ru

1. Register at vdsina.ru
2. Create a server — choose **Ubuntu 22.04**
3. Pick any location outside your target region (Netherlands, Germany, etc.)
4. Note the server's **IP address** and **root password** from the control panel

---

## 2. Connect to the Server

```bash
ssh root@<SERVER_IP>
```

---

## 3. Install Docker

```bash
apt update && apt upgrade -y
apt install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

Verify:

```bash
docker --version
```

---

## 4. Open Port 443

```bash
ufw allow 443/tcp
ufw allow OpenSSH
ufw enable
```

---

## 5. Generate MTProxy Config

`mtg` will generate a secret that makes your traffic look like HTTPS to a real website (domain fronting). Pick any popular site — `google.com`, `cloudflare.com`, etc.

```bash
mkdir -p /opt/mtg && cd /opt/mtg

docker run --rm nineseconds/mtg:2 generate-secret google.com > config.toml

cat config.toml
```

The file will look like:

```toml
secret = "ee473ce5d4958eb5f968c87680a23854..."
bind-to = "0.0.0.0:3128"
```

> The secret already starts with `ee` which activates domain fronting mode. No need to add `dd` manually.

---

## 6. Run the Proxy

```bash
docker run -d \
  --name mtg \
  --restart=unless-stopped \
  -v /opt/mtg/config.toml:/config.toml \
  -p 443:3128 \
  nineseconds/mtg:2
```

Check it started:

```bash
docker ps
docker logs mtg
```

---

## 7. Get the Connection Link

```bash
docker exec mtg /mtg access /config.toml
```

Output example:

```
tg://proxy?server=1.2.3.4&port=443&secret=ee473ce5...
https://t.me/proxy?server=1.2.3.4&port=443&secret=ee473ce5...
```

**Save both links** — these are what users need to connect.

---

## 8. Keep Config Updated (cron)

`mtg` fetches Telegram's internal config on startup, but it's good practice to restart weekly so it picks up any changes:

```bash
crontab -e
```

Add:

```
0 4 * * 0   docker restart mtg
```

---

## Maintenance

| Task | Command |
|---|---|
| Check status | `docker ps` |
| View logs | `docker logs mtg` |
| Restart | `docker restart mtg` |
| Update image | `docker pull nineseconds/mtg:2 && docker restart mtg` |
| Get link again | `docker exec mtg /mtg access /config.toml` |

---

## Troubleshooting

**Port 443 already in use:**
```bash
ss -tlnp | grep 443
# Kill whatever is using it, then re-run docker run
```

**Container exits immediately:**
```bash
docker logs mtg
# Usually a config.toml path issue — confirm file exists at /opt/mtg/config.toml
```

**Users can't connect:**
- Confirm port 443 is open: `ufw status`
- Check vdsina firewall in the control panel (some plans have a separate network-level firewall)
- Try the `https://t.me/proxy?...` link instead of `tg://`
