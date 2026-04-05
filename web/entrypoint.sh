#!/bin/sh
# Docker-based alternative to setup-nginx.sh for serving the credentials page.
# Not used by default — the main setup uses host nginx (see setup-nginx.sh).
# To use: add a nginx service to docker-compose.yml mounting web/ and passing env vars.
set -e

# PAGE_TOKEN is required — the URL itself is the credential (no basic auth)
: "${PAGE_TOKEN:?ERROR: PAGE_TOKEN is not set — pass it via env_file or environment}"

# Compute rotation message (same logic as render-credentials-page.sh)
XRAY_ROTATE_MINS="${XRAY_ROTATE_MINS:-0}"
if echo "$XRAY_ROTATE_MINS" | grep -qE '^[0-9]+$' && [ "$XRAY_ROTATE_MINS" -gt 0 ]; then
  XRAY_ROTATION_MESSAGE="Cover-domain обновляется автоматически каждые ${XRAY_ROTATE_MINS} мин. После следующей ротации старый профиль может перестать подключаться, поэтому заново открой эту страницу и импортируй свежую ссылку или QR-код."
else
  XRAY_ROTATION_MESSAGE="Cover-domain сейчас не ротируется автоматически. Если администратор вручную обновит профиль, заново открой эту страницу и импортируй свежую ссылку или QR-код."
fi
export XRAY_ROTATION_MESSAGE

# Timestamps are injected via env vars when running in Docker (no filesystem access)
XRAY_LAST_ROTATED="${XRAY_LAST_ROTATED:-—}"
MTG_LAST_ROTATED="${MTG_LAST_ROTATED:-—}"
export XRAY_LAST_ROTATED
export MTG_LAST_ROTATED

# Health-check status — injected via env vars in Docker (no filesystem access).
# The _shtml helper mirrors render-credentials-page.sh logic using POSIX sh.
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
export CHECK_OVERALL_CLASS CHECK_OVERALL_LABEL CHECK_TIMESTAMP
export CHECK_MTG_TCP_HTML CHECK_MTG_CTR_HTML CHECK_XRAY_TCP_HTML
export CHECK_SS_TCP_HTML CHECK_XRAY_CTR_HTML CHECK_IPSEC_CTR_HTML

# Serve page at /$PAGE_TOKEN/ so the URL is the credential (mirrors render-credentials-page.sh)
TOKEN_DIR="/usr/share/nginx/html/${PAGE_TOKEN}"
mkdir -p "$TOKEN_DIR"

# Substitute env vars in HTML template.
# List variables explicitly to avoid clobbering nginx's own $uri / $host etc.
envsubst '${SERVER_IP}${MTG_PORT}${MTG_SECRET}${MTG_LINK}${MTG_LAST_ROTATED}${XRAY_UUID}${XRAY_PUBLIC_KEY}${XRAY_SHORT_ID}${XRAY_SNI}${VLESS_URI}${XRAY_ROTATION_MESSAGE}${XRAY_LAST_ROTATED}${SS_URI}${SS_PORT}${SS_METHOD}${SS_PASSWORD}${IKE_PSK}${IKE_USER}${IKE_PASSWORD}${CHECK_OVERALL_CLASS}${CHECK_OVERALL_LABEL}${CHECK_TIMESTAMP}${CHECK_MTG_TCP_HTML}${CHECK_MTG_CTR_HTML}${CHECK_XRAY_TCP_HTML}${CHECK_SS_TCP_HTML}${CHECK_XRAY_CTR_HTML}${CHECK_IPSEC_CTR_HTML}' \
  < /web/index.html.template \
  > "${TOKEN_DIR}/index.html"
cp /web/credentials.js "${TOKEN_DIR}/credentials.js"

# Install nginx config — substitute ${PAGE_TOKEN} into the location block
envsubst '${PAGE_TOKEN}' < /web/nginx.conf > /etc/nginx/conf.d/default.conf

exec nginx -g 'daemon off;'
