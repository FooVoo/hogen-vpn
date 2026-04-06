#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
WEBROOT="${1:-/var/www/vpn}"

[[ -f "$ENV_FILE" ]] || { echo "ERROR: .env not found — run generate-secrets.sh first"; exit 1; }
command -v envsubst >/dev/null 2>&1 || { echo "ERROR: envsubst is not installed"; exit 1; }

set -a; source "$ENV_FILE"; set +a

[[ -n "${PAGE_TOKEN:-}" ]] || { echo "ERROR: PAGE_TOKEN is missing — re-run generate-secrets.sh"; exit 1; }

if [[ "${XRAY_ROTATE_MINS:-0}" =~ ^[0-9]+$ ]] && (( ${XRAY_ROTATE_MINS:-0} > 0 )); then
  XRAY_ROTATION_MESSAGE="Cover-domain обновляется автоматически каждые ${XRAY_ROTATE_MINS:-0} мин. После следующей ротации старый профиль может перестать подключаться, поэтому заново открой эту страницу и импортируй свежую ссылку или QR-код."
else
  XRAY_ROTATION_MESSAGE="Cover-domain сейчас не ротируется автоматически. Если администратор вручную обновит профиль, заново открой эту страницу и импортируй свежую ссылку или QR-код."
fi
export XRAY_ROTATION_MESSAGE

if [[ -f "${SCRIPT_DIR}/.last_xray_rotation" ]]; then
  XRAY_LAST_ROTATED=$(cat "${SCRIPT_DIR}/.last_xray_rotation")
else
  XRAY_LAST_ROTATED="—"
fi
export XRAY_LAST_ROTATED

if [[ -f "${SCRIPT_DIR}/.last_mtg_rotation" ]]; then
  MTG_LAST_ROTATED=$(cat "${SCRIPT_DIR}/.last_mtg_rotation")
else
  MTG_LAST_ROTATED="—"
fi
export MTG_LAST_ROTATED

# ── Health-check status ───────────────────────────────────────────────────────
if [[ -f "${SCRIPT_DIR}/.check_env" ]]; then
  set -a; source "${SCRIPT_DIR}/.check_env"; set +a
fi

_shtml() {
  case "${1:-}" in
    up)   printf '<span class="s-up">UP</span>' ;;
    down) printf '<span class="s-down">DOWN</span>' ;;
    *)    printf '<span class="s-dim">—</span>' ;;
  esac
}
case "${CHECK_OVERALL:-}" in
  ok)       CHECK_OVERALL_CLASS="s-ok";       CHECK_OVERALL_LABEL="OK"       ;;
  degraded) CHECK_OVERALL_CLASS="s-degraded"; CHECK_OVERALL_LABEL="DEGRADED" ;;
  *)        CHECK_OVERALL_CLASS="s-dim";      CHECK_OVERALL_LABEL="—"        ;;
esac
: "${CHECK_TIMESTAMP:=—}"
CHECK_MTG_TCP_HTML=$(_shtml "${CHECK_MTG_TCP:-}")
CHECK_MTG_CTR_HTML=$(_shtml "${CHECK_MTG_CTR:-}")
CHECK_XRAY_TCP_HTML=$(_shtml "${CHECK_XRAY_TCP:-}")
CHECK_SS_TCP_HTML=$(_shtml "${CHECK_SS_TCP:-}")
CHECK_XRAY_CTR_HTML=$(_shtml "${CHECK_XRAY_CTR:-}")
CHECK_IPSEC_CTR_HTML=$(_shtml "${CHECK_IPSEC_CTR:-}")
CHECK_WG_CTR_HTML=$(_shtml "${CHECK_WG_CTR:-}")
export CHECK_OVERALL_CLASS CHECK_OVERALL_LABEL CHECK_TIMESTAMP
export CHECK_MTG_TCP_HTML CHECK_MTG_CTR_HTML CHECK_XRAY_TCP_HTML
export CHECK_SS_TCP_HTML CHECK_XRAY_CTR_HTML CHECK_IPSEC_CTR_HTML CHECK_WG_CTR_HTML

# Serve the page at $WEBROOT/$PAGE_TOKEN/index.html so the URL is the credential.
# Anyone with the link can access it; no browser auth dialog needed.
TOKEN_DIR="${WEBROOT}/${PAGE_TOKEN}"
mkdir -p "$TOKEN_DIR"
envsubst '${SERVER_IP}${MTG_PORT}${MTG_SECRET}${MTG_LINK}${MTG_LAST_ROTATED}${XRAY_UUID}${XRAY_PUBLIC_KEY}${XRAY_SHORT_ID}${XRAY_SNI}${VLESS_URI}${XRAY_ROTATION_MESSAGE}${XRAY_LAST_ROTATED}${SS_URI}${SS_PORT}${SS_METHOD}${SS_PASSWORD}${IKE_PSK}${IKE_USER}${IKE_PASSWORD}${WG_PORT}${WG_SERVER_PUBLIC_KEY}${WG_CLIENT_PRIVATE_KEY}${WG_CLIENT_IP}${WG_PSK}${CHECK_OVERALL_CLASS}${CHECK_OVERALL_LABEL}${CHECK_TIMESTAMP}${CHECK_MTG_TCP_HTML}${CHECK_MTG_CTR_HTML}${CHECK_XRAY_TCP_HTML}${CHECK_SS_TCP_HTML}${CHECK_XRAY_CTR_HTML}${CHECK_IPSEC_CTR_HTML}${CHECK_WG_CTR_HTML}' \
  < "${SCRIPT_DIR}/web/index.html.template" \
  > "${TOKEN_DIR}/index.html"
cp "${SCRIPT_DIR}/web/credentials.js" "${TOKEN_DIR}/credentials.js"

# Write downloadable WireGuard client config into the token directory.
# The client private key lives here; the token URL is the only protection.
if [[ -n "${WG_CLIENT_PRIVATE_KEY:-}" && -n "${WG_SERVER_PUBLIC_KEY:-}" ]]; then
  cat > "${TOKEN_DIR}/wg-client.conf" <<WG_EOF
[Interface]
PrivateKey = ${WG_CLIENT_PRIVATE_KEY}
Address    = ${WG_CLIENT_IP:-10.13.13.2}/24
DNS        = 1.1.1.1, 8.8.8.8
MTU        = 1420

[Peer]
PublicKey           = ${WG_SERVER_PUBLIC_KEY}
PresharedKey        = ${WG_PSK:-}
AllowedIPs          = 0.0.0.0/0
Endpoint            = ${SERVER_IP}:${WG_PORT:-51820}
PersistentKeepalive = 25
WG_EOF
  chmod 640 "${TOKEN_DIR}/wg-client.conf"
fi
