#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_IP="${1:-}"
if [[ -z "$SERVER_IP" ]]; then
  echo "Usage: ./generate-secrets.sh <SERVER_IP> [REALITY_COVER_DOMAIN] [CREDENTIALS_DOMAIN]"
  echo "Example: ./generate-secrets.sh 1.2.3.4"
  echo "Example: ./generate-secrets.sh 1.2.3.4 github.com vpn.example.com"
  exit 1
fi

REALITY_COVER_DOMAIN="${2:-}"
CREDENTIALS_DOMAIN="${3:-}"

if [[ -f .env ]]; then
  echo "ERROR: .env already exists. Delete it first to regenerate secrets."
  exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is not installed"; exit 1; }

echo "Pulling images..."
docker pull --quiet nineseconds/mtg:2 >/dev/null
docker pull --quiet ghcr.io/xtls/xray-core:26.3.27 >/dev/null
docker pull --quiet hwdsl2/ipsec-vpn-server:latest >/dev/null
docker pull --quiet lscr.io/linuxserver/wireguard:latest >/dev/null

echo "Generating VLESS credentials..."
if [[ -f /proc/sys/kernel/random/uuid ]]; then
  XRAY_UUID=$(cat /proc/sys/kernel/random/uuid)
else
  XRAY_UUID=$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null \
    || uuidgen \
    || { echo "ERROR: cannot generate UUID — install python3 or uuidgen"; exit 1; })
fi
XRAY_KEYPAIR=$(docker run --rm ghcr.io/xtls/xray-core:26.3.27 x25519)
# v26.x output: "PrivateKey: xxx" / "Password (PublicKey): xxx"
# v1.x output:  "Private key: xxx" / "Public key: xxx"
XRAY_PRIVATE_KEY=$(echo "$XRAY_KEYPAIR" | awk -F': *' '/^PrivateKey:|^Private key:/{print $2; exit}')
XRAY_PUBLIC_KEY=$(echo "$XRAY_KEYPAIR"  | awk -F': *' '/Password \(PublicKey\):|^Public key:/{print $2; exit}')
XRAY_SHORT_ID=$(openssl rand -hex 8)

# Unified cover-domain pool — used by both REALITY SNI fronting and MTProxy FakeTLS.
# All entries must support TLS 1.3 on port 443.
COVER_DOMAINS=(
  # International — accessible from Russia
  "www.microsoft.com"
  "www.cloudflare.com"
  "github.com"
  "www.bing.com"
  "www.apple.com"
  "www.google.com"
  "www.samsung.com"
  "www.nvidia.com"
  "www.intel.com"
  "www.oracle.com"
  "www.ibm.com"
  "learn.microsoft.com"
  "www.lenovo.com"
  "www.amd.com"
  "www.hp.com"
  "www.cisco.com"
  "www.jetbrains.com"
  "www.aliexpress.com"
  "www.yahoo.com"
  "www.docker.com"
  # Russian domestic — high-traffic, unsuspicious from RU IPs
  "www.yandex.ru"
  "mail.ru"
  "www.vk.com"
  "www.ozon.ru"
  "www.wildberries.ru"
  "www.sberbank.ru"
  "www.tinkoff.ru"
  "www.gosuslugi.ru"
  "www.avito.ru"
  "habr.com"
  "www.kaspersky.ru"
  "www.dns-shop.ru"
  "www.mos.ru"
  "www.rt.com"
  "www.gazprom.ru"
)
if [[ -n "$REALITY_COVER_DOMAIN" ]]; then
  XRAY_SNI="${REALITY_COVER_DOMAIN#https://}"
  XRAY_SNI="${XRAY_SNI#http://}"
  XRAY_SNI="${XRAY_SNI%%/*}"
  XRAY_SNI="${XRAY_SNI%%:*}"
  DOMAIN_IN_POOL=false
  for _D in "${COVER_DOMAINS[@]}"; do
    [[ "$_D" == "$XRAY_SNI" ]] && { DOMAIN_IN_POOL=true; break; }
  done
  [[ "$DOMAIN_IN_POOL" == true ]] || COVER_DOMAINS=("$XRAY_SNI" "${COVER_DOMAINS[@]}")
else
  XRAY_SNI="${COVER_DOMAINS[$RANDOM % ${#COVER_DOMAINS[@]}]}"
fi
if [[ -z "$XRAY_SNI" || -z "$XRAY_PRIVATE_KEY" || -z "$XRAY_PUBLIC_KEY" ]]; then
  echo "ERROR: failed to generate REALITY credentials"
  exit 1
fi
XRAY_COVER_DOMAINS=$(IFS=,; echo "${COVER_DOMAINS[*]}")
XRAY_ROTATE_MINS=120
XRAY_DEST="${XRAY_SNI}:443"

echo "Generating MTProxy secret..."
MTG_PORT=2083
mkdir -p mtg
MTG_COVER_DOMAIN="${COVER_DOMAINS[$RANDOM % ${#COVER_DOMAINS[@]}]}"
MTG_COVER_DOMAINS="$XRAY_COVER_DOMAINS"
MTG_ROTATE_MINS=120
MTG_SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret "$MTG_COVER_DOMAIN")
[[ "$MTG_SECRET" =~ ^ee[0-9a-f]{32,}$ ]] || [[ "$MTG_SECRET" =~ ^[A-Za-z0-9_-]{32,}=*$ ]] || {
  echo "ERROR: MTProxy secret has unexpected format: '${MTG_SECRET:0:40}'"
  exit 1
}
cat > mtg/config.toml <<EOF
secret = "${MTG_SECRET}"
bind-to = "0.0.0.0:3128"
EOF
chmod 600 mtg/config.toml

echo "Generating page credentials..."
PAGE_TOKEN=$(openssl rand -hex 16)

echo "Generating Shadowsocks credentials..."
SS_METHOD="2022-blake3-aes-256-gcm"
SS_PORT=8388
SS_PASSWORD=$(openssl rand -base64 32 | tr -d '\n')
SS_USERINFO=$(printf '%s:%s' "$SS_METHOD" "$SS_PASSWORD" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
SS_URI="ss://${SS_USERINFO}@${SERVER_IP}:${SS_PORT}#SS-VPN"

echo "Generating IKEv2 credentials..."
IKE_PSK=$(openssl rand -base64 24 | tr -d '\n')
IKE_USER="vpn$(openssl rand -hex 4)"
IKE_PASSWORD=$(openssl rand -hex 8)

echo "Generating WireGuard credentials..."
WG_PORT=51820
WG_CLIENT_IP="10.13.13.2"
# All key generation in a single container call — alpine + wireguard-tools
WG_KEYS=$(docker run --rm alpine:3 sh -c \
  "apk add -q wireguard-tools 2>/dev/null; \
   srv_priv=\$(wg genkey); \
   srv_pub=\$(printf '%s' \"\$srv_priv\" | wg pubkey); \
   cli_priv=\$(wg genkey); \
   cli_pub=\$(printf '%s' \"\$cli_priv\" | wg pubkey); \
   psk=\$(wg genpsk); \
   printf '%s\n%s\n%s\n%s\n%s\n' \"\$srv_priv\" \"\$srv_pub\" \"\$cli_priv\" \"\$cli_pub\" \"\$psk\"")
WG_SERVER_PRIVATE=$(printf '%s' "$WG_KEYS" | sed -n '1p')
WG_SERVER_PUBLIC=$(printf '%s' "$WG_KEYS" | sed -n '2p')
WG_CLIENT_PRIVATE=$(printf '%s' "$WG_KEYS" | sed -n '3p')
WG_CLIENT_PUBLIC=$(printf '%s' "$WG_KEYS" | sed -n '4p')
WG_PSK=$(printf '%s' "$WG_KEYS" | sed -n '5p')
[[ -n "$WG_SERVER_PRIVATE" && -n "$WG_CLIENT_PRIVATE" && -n "$WG_PSK" ]] || {
  echo "ERROR: failed to generate WireGuard credentials"
  exit 1
}

# Write WireGuard server config (mounted read-only into the container).
# Docker Compose creates missing bind-mount paths as directories; remove any
# such stale directory before writing the file.
rm -rf wireguard/wg0.conf
mkdir -p wireguard
cat > wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = ${WG_SERVER_PRIVATE}
Address = 10.13.13.1/24
ListenPort = ${WG_PORT}
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.13.13.0/24 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -j MASQUERADE

[Peer]
# peer1
PublicKey    = ${WG_CLIENT_PUBLIC}
PresharedKey = ${WG_PSK}
AllowedIPs   = ${WG_CLIENT_IP}/32
EOF
chmod 600 wireguard/wg0.conf

# Write client config (for credential distribution; includes private key)
rm -rf wireguard/peer1.conf
cat > wireguard/peer1.conf <<EOF
[Interface]
PrivateKey = ${WG_CLIENT_PRIVATE}
Address    = ${WG_CLIENT_IP}/24
DNS        = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey           = ${WG_SERVER_PUBLIC}
PresharedKey        = ${WG_PSK}
AllowedIPs          = 0.0.0.0/0, ::/0
Endpoint            = ${SERVER_IP}:${WG_PORT}
PersistentKeepalive = 25
EOF
chmod 600 wireguard/peer1.conf

# Composite connection strings
MTG_LINK="https://t.me/proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${MTG_SECRET}"
VLESS_URI="vless://${XRAY_UUID}@${SERVER_IP}:8443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${XRAY_SNI}&fp=chrome&pbk=${XRAY_PUBLIC_KEY}&sid=${XRAY_SHORT_ID}&type=tcp#VPN"

# Write .env
cat > .env <<EOF
SERVER_IP=${SERVER_IP}

MTG_SECRET=${MTG_SECRET}
MTG_PORT=${MTG_PORT}
MTG_COVER_DOMAIN=${MTG_COVER_DOMAIN}
MTG_COVER_DOMAINS=${MTG_COVER_DOMAINS}
MTG_LINK="${MTG_LINK}"
MTG_ROTATE_MINS=${MTG_ROTATE_MINS}

XRAY_UUID=${XRAY_UUID}
XRAY_PRIVATE_KEY=${XRAY_PRIVATE_KEY}
XRAY_PUBLIC_KEY=${XRAY_PUBLIC_KEY}
XRAY_SHORT_ID=${XRAY_SHORT_ID}
XRAY_SNI=${XRAY_SNI}
XRAY_DEST=${XRAY_DEST}
XRAY_COVER_DOMAINS=${XRAY_COVER_DOMAINS}
XRAY_ROTATE_MINS=${XRAY_ROTATE_MINS}
VLESS_URI="${VLESS_URI}"

SS_METHOD=${SS_METHOD}
SS_PORT=${SS_PORT}
SS_PASSWORD="${SS_PASSWORD}"
SS_URI="${SS_URI}"

IKE_PSK="${IKE_PSK}"
IKE_USER=${IKE_USER}
IKE_PASSWORD=${IKE_PASSWORD}

WG_PORT=${WG_PORT}
WG_SERVER_PUBLIC_KEY=${WG_SERVER_PUBLIC}
WG_CLIENT_PRIVATE_KEY=${WG_CLIENT_PRIVATE}
WG_CLIENT_PUBLIC_KEY=${WG_CLIENT_PUBLIC}
WG_PSK=${WG_PSK}
WG_CLIENT_IP=${WG_CLIENT_IP}

PAGE_TOKEN=${PAGE_TOKEN}

# Domain for the nginx credentials page (required by setup-nginx.sh)
CREDENTIALS_DOMAIN=${CREDENTIALS_DOMAIN}
# Webroot for the credentials page (default: /var/www/vpn)
CREDENTIALS_WEBROOT=/var/www/vpn
EOF
chmod 600 .env

"$SCRIPT_DIR/render-xray-config.sh"

echo ""
echo "Done. Files written:"
echo "  .env              — all credentials"
echo "  mtg/config.toml   — MTProxy config"
echo "  xray/config.json  — VLESS + Shadowsocks config"
echo "  wireguard/wg0.conf   — WireGuard server config"
echo "  wireguard/peer1.conf — WireGuard client config"
echo ""
echo "REALITY cover domain:  ${XRAY_SNI}"
echo "MTProxy cover domain:  ${MTG_COVER_DOMAIN}"
echo "Shadowsocks method:    ${SS_METHOD}"
echo "IKEv2 user:            ${IKE_USER}"
echo "WireGuard client IP:   ${WG_CLIENT_IP}"
echo ""
echo "Credentials page token:  ${PAGE_TOKEN}"
echo "(Share URL: https://<CREDENTIALS_DOMAIN>/${PAGE_TOKEN}/)"
echo ""
echo "Next: ./setup-nginx.sh && docker compose up -d"
