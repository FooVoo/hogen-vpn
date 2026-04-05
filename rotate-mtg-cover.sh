#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
WEBROOT="${WEBROOT:-/var/www/vpn}"

[[ -f "$ENV_FILE" ]] || { echo "ERROR: .env not found — run generate-secrets.sh first"; exit 1; }

set -a; source "$ENV_FILE"; set +a

[[ -n "${MTG_SECRET:-}" ]]       || { echo "ERROR: MTG_SECRET is missing"; exit 1; }
[[ -n "${MTG_PORT:-}" ]]         || { echo "ERROR: MTG_PORT is missing"; exit 1; }
[[ -n "${MTG_LINK:-}" ]]         || { echo "ERROR: MTG_LINK is missing"; exit 1; }
[[ -n "${SERVER_IP:-}" ]]        || { echo "ERROR: SERVER_IP is missing"; exit 1; }

MTG_COVER_DOMAINS="${MTG_COVER_DOMAINS:-${XRAY_COVER_DOMAINS:-}}"
MTG_COVER_DOMAIN="${MTG_COVER_DOMAIN:-${XRAY_SNI:-}}"
MTG_ROTATE_MINS="${MTG_ROTATE_MINS:-30}"
XRAY_ROTATE_MINS="${XRAY_ROTATE_MINS:-30}"

[[ -n "$MTG_COVER_DOMAINS" ]] || { echo "ERROR: MTG_COVER_DOMAINS is missing"; exit 1; }
[[ -n "$MTG_COVER_DOMAIN" ]]  || { echo "ERROR: MTG_COVER_DOMAIN is missing"; exit 1; }

CURRENT_MTG_DOMAIN="$MTG_COVER_DOMAIN"
IFS=',' read -r -a MTG_DOMAIN_POOL <<< "$MTG_COVER_DOMAINS"

MTG_CANDIDATES=()
for D in "${MTG_DOMAIN_POOL[@]}"; do
  [[ -n "$D" && "$D" != "$CURRENT_MTG_DOMAIN" ]] && MTG_CANDIDATES+=("$D")
done

if (( ${#MTG_CANDIDATES[@]} > 0 )); then
  NEXT_MTG_DOMAIN="${MTG_CANDIDATES[$RANDOM % ${#MTG_CANDIDATES[@]}]}"
else
  NEXT_MTG_DOMAIN="$CURRENT_MTG_DOMAIN"
fi

MTG_SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret "$NEXT_MTG_DOMAIN")
[[ "$MTG_SECRET" =~ ^ee[0-9a-f]{32,}$ ]] || [[ "$MTG_SECRET" =~ ^[A-Za-z0-9_-]{32,}=*$ ]] || {
  echo "ERROR: MTProxy secret has unexpected format: '${MTG_SECRET:0:40}'"
  exit 1
}

MTG_COVER_DOMAIN="$NEXT_MTG_DOMAIN"
MTG_LINK="https://t.me/proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${MTG_SECRET}"

mkdir -p "${SCRIPT_DIR}/mtg"
cat > "${SCRIPT_DIR}/mtg/config.toml" <<EOF
secret = "${MTG_SECRET}"
bind-to = "0.0.0.0:3128"
EOF
chmod 600 "${SCRIPT_DIR}/mtg/config.toml"

TMP_ENV="$(mktemp)"
chmod 600 "$TMP_ENV"
trap 'rm -f "$TMP_ENV"' EXIT
cat > "$TMP_ENV" <<EOF
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

PAGE_TOKEN=${PAGE_TOKEN}

CREDENTIALS_DOMAIN=${CREDENTIALS_DOMAIN:-}
CREDENTIALS_WEBROOT=${CREDENTIALS_WEBROOT:-/var/www/vpn}
NGINX_VHOST_PATH=${NGINX_VHOST_PATH:-}
EOF
mv "$TMP_ENV" "$ENV_FILE"

"$SCRIPT_DIR/render-credentials-page.sh" "$WEBROOT"

docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d --force-recreate mtg >/dev/null

date '+%Y-%m-%d %H:%M %Z' > "${SCRIPT_DIR}/.last_mtg_rotation"

echo "Rotated MTProxy fingerprint: ${CURRENT_MTG_DOMAIN} -> ${MTG_COVER_DOMAIN}"
