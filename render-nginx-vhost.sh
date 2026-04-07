#!/usr/bin/env bash
# Re-renders the nginx vhost from web/nginx-vhost.conf.template and reloads nginx.
# Called by deploy.sh on every deploy so nginx picks up template changes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

[[ $EUID -eq 0 ]] || { log_error "Run as root (sudo ./render-nginx-vhost.sh)"; exit 1; }
[[ -f "$SCRIPT_DIR/.env" ]] || { log_error ".env not found — run generate-secrets.sh first"; exit 1; }

set -a; source "$SCRIPT_DIR/.env"; set +a

[[ -n "${CREDENTIALS_DOMAIN:-}" ]] || { log_error "CREDENTIALS_DOMAIN missing in .env"; exit 1; }
[[ -n "${PAGE_TOKEN:-}" ]]        || { log_error "PAGE_TOKEN missing in .env"; exit 1; }

WEBROOT="${CREDENTIALS_WEBROOT:-/var/www/vpn}"
VHOST_PATH="${NGINX_VHOST_PATH:-/etc/nginx/sites-available/vpn}"

export CREDENTIALS_DOMAIN WEBROOT PAGE_TOKEN
envsubst '${CREDENTIALS_DOMAIN}${WEBROOT}${PAGE_TOKEN}' \
  < "$SCRIPT_DIR/web/nginx-vhost.conf.template" \
  > "$VHOST_PATH"

nginx -t
systemctl reload nginx
log_ok "nginx vhost re-rendered → ${VHOST_PATH}"
