#!/bin/sh
# Docker-based alternative to setup-nginx.sh for serving the credentials page.
# Not used by default — the main setup uses host nginx (see setup-nginx.sh).
# To use: add a nginx service to docker-compose.yml mounting web/ and passing env vars.
set -e

# PAGE_TOKEN is required — the URL itself is the credential (no basic auth)
: "${PAGE_TOKEN:?ERROR: PAGE_TOKEN is not set — pass it via env_file or environment}"

# Compute rotation message (same logic as render-credentials-page.sh)
XRAY_ROTATE_HOURS="${XRAY_ROTATE_HOURS:-0}"
if echo "$XRAY_ROTATE_HOURS" | grep -qE '^[0-9]+$' && [ "$XRAY_ROTATE_HOURS" -gt 0 ]; then
  XRAY_ROTATION_MESSAGE="Cover-domain обновляется автоматически каждые ${XRAY_ROTATE_HOURS} ч. После следующей ротации старый профиль может перестать подключаться, поэтому заново открой эту страницу и импортируй свежую ссылку или QR-код."
else
  XRAY_ROTATION_MESSAGE="Cover-domain сейчас не ротируется автоматически. Если администратор вручную обновит профиль, заново открой эту страницу и импортируй свежую ссылку или QR-код."
fi
export XRAY_ROTATION_MESSAGE

# Serve page at /$PAGE_TOKEN/ so the URL is the credential (mirrors render-credentials-page.sh)
TOKEN_DIR="/usr/share/nginx/html/${PAGE_TOKEN}"
mkdir -p "$TOKEN_DIR"

# Substitute env vars in HTML template.
# List variables explicitly to avoid clobbering nginx's own $uri / $host etc.
envsubst '${SERVER_IP}${MTG_PORT}${MTG_SECRET}${MTG_LINK}${XRAY_UUID}${XRAY_PUBLIC_KEY}${XRAY_SHORT_ID}${XRAY_SNI}${VLESS_URI}${XRAY_ROTATION_MESSAGE}${SS_URI}${SS_PORT}${SS_METHOD}${SS_PASSWORD}${IKE_PSK}${IKE_USER}${IKE_PASSWORD}' \
  < /web/index.html.template \
  > "${TOKEN_DIR}/index.html"

# Install nginx config — substitute ${PAGE_TOKEN} into the location block
envsubst '${PAGE_TOKEN}' < /web/nginx.conf > /etc/nginx/conf.d/default.conf

exec nginx -g 'daemon off;'
