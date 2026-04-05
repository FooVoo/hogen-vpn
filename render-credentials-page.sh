#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
WEBROOT="${1:-/var/www/vpn}"

[[ -f "$ENV_FILE" ]] || { echo "ERROR: .env not found — run generate-secrets.sh first"; exit 1; }
command -v envsubst >/dev/null 2>&1 || { echo "ERROR: envsubst is not installed"; exit 1; }

set -a; source "$ENV_FILE"; set +a

[[ -n "${PAGE_TOKEN:-}" ]] || { echo "ERROR: PAGE_TOKEN is missing — re-run generate-secrets.sh"; exit 1; }

if [[ "${XRAY_ROTATE_HOURS:-0}" =~ ^[0-9]+$ ]] && (( XRAY_ROTATE_HOURS > 0 )); then
  XRAY_ROTATION_MESSAGE="Cover-domain обновляется автоматически каждые ${XRAY_ROTATE_HOURS} ч. После следующей ротации старый профиль может перестать подключаться, поэтому заново открой эту страницу и импортируй свежую ссылку или QR-код."
else
  XRAY_ROTATION_MESSAGE="Cover-domain сейчас не ротируется автоматически. Если администратор вручную обновит профиль, заново открой эту страницу и импортируй свежую ссылку или QR-код."
fi
export XRAY_ROTATION_MESSAGE

# Serve the page at $WEBROOT/$PAGE_TOKEN/index.html so the URL is the credential.
# Anyone with the link can access it; no browser auth dialog needed.
TOKEN_DIR="${WEBROOT}/${PAGE_TOKEN}"
mkdir -p "$TOKEN_DIR"
envsubst '${SERVER_IP}${MTG_PORT}${MTG_SECRET}${MTG_LINK}${XRAY_UUID}${XRAY_PUBLIC_KEY}${XRAY_SHORT_ID}${XRAY_SNI}${VLESS_URI}${XRAY_ROTATION_MESSAGE}${SS_URI}${SS_PORT}${SS_METHOD}${SS_PASSWORD}${IKE_PSK}${IKE_USER}${IKE_PASSWORD}' \
  < "${SCRIPT_DIR}/web/index.html.template" \
  > "${TOKEN_DIR}/index.html"
cp "${SCRIPT_DIR}/web/credentials.js" "${TOKEN_DIR}/credentials.js"
