#!/usr/bin/env bash
set -euo pipefail

SERVER_IP="${1:-}"
if [[ -z "$SERVER_IP" ]]; then
  echo "Usage: ./generate-secrets.sh <SERVER_IP> [REALITY_COVER_DOMAIN]"
  echo "Example: ./generate-secrets.sh 1.2.3.4"
  echo "Example: ./generate-secrets.sh 1.2.3.4 github.com"
  exit 1
fi

REALITY_COVER_DOMAIN="${2:-}"

if [[ -f .env ]]; then
  echo "ERROR: .env already exists. Delete it first to regenerate secrets."
  exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is not installed"; exit 1; }

echo "Pulling images..."
docker pull nineseconds/mtg:2 --quiet >/dev/null
docker pull ghcr.io/xtls/xray-core --quiet >/dev/null

echo "Generating MTProxy secret..."
mkdir -p mtg
MTG_SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret google.com)
cat > mtg/config.toml <<EOF
secret = "${MTG_SECRET}"
bind-to = "0.0.0.0:3128"
EOF

echo "Generating VLESS credentials..."
XRAY_UUID=$(cat /proc/sys/kernel/random/uuid)
XRAY_KEYPAIR=$(docker run --rm ghcr.io/xtls/xray-core x25519)
XRAY_PRIVATE_KEY=$(echo "$XRAY_KEYPAIR" | awk -F': *' '{key=$1; gsub(/ /, "", key); if (tolower(key)=="privatekey") print $2}')
XRAY_PUBLIC_KEY=$(echo "$XRAY_KEYPAIR"  | awk -F': *' '{key=$1; gsub(/ /, "", key); if (tolower(key)=="publickey") print $2}')
XRAY_SHORT_ID=$(openssl rand -hex 8)
REALITY_COVER_DOMAINS=(
  "www.microsoft.com"
  "github.com"
  "www.bing.com"
  "www.office.com"
)
if [[ -n "$REALITY_COVER_DOMAIN" ]]; then
  XRAY_SNI="${REALITY_COVER_DOMAIN#https://}"
  XRAY_SNI="${XRAY_SNI%%/*}"
  XRAY_SNI="${XRAY_SNI%%:*}"
else
  XRAY_SNI="${REALITY_COVER_DOMAINS[$RANDOM % ${#REALITY_COVER_DOMAINS[@]}]}"
fi
if [[ -z "$XRAY_SNI" || -z "$XRAY_PRIVATE_KEY" || -z "$XRAY_PUBLIC_KEY" ]]; then
  echo "ERROR: failed to generate REALITY credentials"
  exit 1
fi
XRAY_DEST="${XRAY_SNI}:443"

echo "Generating page credentials..."
PAGE_USER="admin"
PAGE_PASSWORD=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)

MTG_PORT=2083

# Composite connection strings
MTG_LINK="https://t.me/proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${MTG_SECRET}"
VLESS_URI="vless://${XRAY_UUID}@${SERVER_IP}:8443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${XRAY_SNI}&fp=chrome&pbk=${XRAY_PUBLIC_KEY}&sid=${XRAY_SHORT_ID}&type=tcp#VPN"

# Write .env
cat > .env <<EOF
SERVER_IP=${SERVER_IP}

MTG_SECRET=${MTG_SECRET}
MTG_PORT=${MTG_PORT}
MTG_LINK="${MTG_LINK}"

XRAY_UUID=${XRAY_UUID}
XRAY_PRIVATE_KEY=${XRAY_PRIVATE_KEY}
XRAY_PUBLIC_KEY=${XRAY_PUBLIC_KEY}
XRAY_SHORT_ID=${XRAY_SHORT_ID}
XRAY_SNI=${XRAY_SNI}
XRAY_DEST=${XRAY_DEST}
VLESS_URI="${VLESS_URI}"

PAGE_USER=${PAGE_USER}
PAGE_PASSWORD=${PAGE_PASSWORD}
EOF

# Write xray config
mkdir -p xray
cat > xray/config.json <<EOF
{
    "log": { "loglevel": "warning" },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": 8443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${XRAY_UUID}",
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
                    "dest": "${XRAY_DEST}",
                    "serverNames": ["${XRAY_SNI}"],
                    "privateKey": "${XRAY_PRIVATE_KEY}",
                    "shortIds": ["${XRAY_SHORT_ID}"],
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
EOF

echo ""
echo "Done. Files written:"
echo "  .env              — all credentials"
echo "  mtg/config.toml   — MTProxy config"
echo "  xray/config.json  — VLESS config"
echo ""
echo "REALITY cover domain: ${XRAY_SNI}"
echo ""
echo "Credentials page login:  ${PAGE_USER} / ${PAGE_PASSWORD}"
echo ""
echo "Next: ./setup-nginx.sh && docker compose up -d"
