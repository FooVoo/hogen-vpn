#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
docker pull ghcr.io/xtls/xray-core:v26.3.27 --quiet >/dev/null

echo "Generating MTProxy secret..."
mkdir -p mtg
MTG_SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret google.com)
cat > mtg/config.toml <<EOF
secret = "${MTG_SECRET}"
bind-to = "0.0.0.0:3128"
EOF

echo "Generating VLESS credentials..."
if [[ -f /proc/sys/kernel/random/uuid ]]; then
  XRAY_UUID=$(cat /proc/sys/kernel/random/uuid)
else
  XRAY_UUID=$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null \
    || uuidgen \
    || { echo "ERROR: cannot generate UUID — install python3 or uuidgen"; exit 1; })
fi
XRAY_KEYPAIR=$(docker run --rm ghcr.io/xtls/xray-core:v26.3.27 x25519)
XRAY_PRIVATE_KEY=$(echo "$XRAY_KEYPAIR" | awk -F': *' '{key=$1; gsub(/ /, "", key); if (tolower(key)=="privatekey") print $2}')
XRAY_PUBLIC_KEY=$(echo "$XRAY_KEYPAIR"  | awk -F': *' '{key=$1; gsub(/ /, "", key); if (tolower(key)=="publickey") print $2}')
XRAY_SHORT_ID=$(openssl rand -hex 8)
REALITY_COVER_DOMAINS=(
  "www.microsoft.com"
  "www.cloudflare.com"
  "github.com"
  "www.bing.com"
  "www.office.com"
  "www.apple.com"
  "www.google.com"
  "www.amazon.com"
  "www.mozilla.org"
  "www.wikipedia.org"
  "www.whatsapp.com"
  "www.signal.org"
  "www.tesla.com"
  "www.nvidia.com"
  "www.intel.com"
  "www.samsung.com"
  "www.oracle.com"
  "www.ibm.com"
  "www.adobe.com"
  "www.spotify.com"
  "www.netflix.com"
  "www.docker.com"
  "www.github.io"
  "www.atlassian.com"
  "www.notion.so"
  "www.figma.com"
  "www.stripe.com"
  "www.twitch.tv"
  "www.reddit.com"
  "www.stackoverflow.com"
  "www.npmjs.com"
  "www.python.org"
  "www.rust-lang.org"
  "www.golang.org"
  "www.swift.org"
)
if [[ -n "$REALITY_COVER_DOMAIN" ]]; then
  XRAY_SNI="${REALITY_COVER_DOMAIN#https://}"
  XRAY_SNI="${XRAY_SNI%%/*}"
  XRAY_SNI="${XRAY_SNI%%:*}"
  DOMAIN_IN_POOL=false
  for COVER_DOMAIN in "${REALITY_COVER_DOMAINS[@]}"; do
    if [[ "$COVER_DOMAIN" == "$XRAY_SNI" ]]; then
      DOMAIN_IN_POOL=true
      break
    fi
  done
  if [[ "$DOMAIN_IN_POOL" == false ]]; then
    REALITY_COVER_DOMAINS=("$XRAY_SNI" "${REALITY_COVER_DOMAINS[@]}")
  fi
else
  XRAY_SNI="${REALITY_COVER_DOMAINS[$RANDOM % ${#REALITY_COVER_DOMAINS[@]}]}"
fi
if [[ -z "$XRAY_SNI" || -z "$XRAY_PRIVATE_KEY" || -z "$XRAY_PUBLIC_KEY" ]]; then
  echo "ERROR: failed to generate REALITY credentials"
  exit 1
fi
XRAY_COVER_DOMAINS=$(IFS=,; echo "${REALITY_COVER_DOMAINS[*]}")
XRAY_ROTATE_HOURS=6
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
XRAY_COVER_DOMAINS=${XRAY_COVER_DOMAINS}
XRAY_ROTATE_HOURS=${XRAY_ROTATE_HOURS}
VLESS_URI="${VLESS_URI}"

PAGE_USER=${PAGE_USER}
PAGE_PASSWORD=${PAGE_PASSWORD}
EOF

"$SCRIPT_DIR/render-xray-config.sh"

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
