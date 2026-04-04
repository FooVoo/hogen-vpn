#!/usr/bin/env bash
# Run on the server after generate-secrets.sh.
# Sets up nginx vhost for universal.ramilkarimov.me + SSL + firewall rules.
set -euo pipefail

DOMAIN="universal.ramilkarimov.me"
WEBROOT="/var/www/vpn"
VHOST_PATH="/etc/nginx/sites-available/vpn"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
[[ -f "$SCRIPT_DIR/.env" ]] || { echo "ERROR: .env not found — run generate-secrets.sh first"; exit 1; }

# Load credentials
set -a; source "$SCRIPT_DIR/.env"; set +a

# Install tools
apt-get install -y --quiet certbot python3-certbot-nginx gettext-base

# Open firewall ports
ufw allow 80/tcp  comment "HTTP"
ufw allow 443/tcp comment "HTTPS"
ufw allow 2083/tcp comment "MTProxy"
ufw allow 8443/tcp comment "VLESS"

# Generate HTML credentials page
"$SCRIPT_DIR/render-credentials-page.sh" "$WEBROOT"

# Generate htpasswd
printf '%s:%s\n' "$PAGE_USER" "$(openssl passwd -apr1 "$PAGE_PASSWORD")" \
  > /etc/nginx/htpasswd-vpn
chown root:www-data /etc/nginx/htpasswd-vpn
chmod 640 /etc/nginx/htpasswd-vpn

# Install nginx vhost
cp "$SCRIPT_DIR/web/nginx-vhost.conf" "$VHOST_PATH"
ln -sf "$VHOST_PATH" /etc/nginx/sites-enabled/vpn
nginx -t
systemctl reload nginx

# Get SSL certificate (certbot will update the vhost automatically)
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
  --register-unsafely-without-email --redirect

ROTATION_SERVICE_PATH="/etc/systemd/system/vpn-reality-cover-rotate.service"
ROTATION_TIMER_PATH="/etc/systemd/system/vpn-reality-cover-rotate.timer"
ROTATION_INTERVAL="${XRAY_ROTATE_HOURS:-0}"
ROTATION_REASON=""

if [[ -z "${XRAY_COVER_DOMAINS:-}" ]]; then
  ROTATION_REASON="XRAY_COVER_DOMAINS is missing in .env. Regenerate secrets or add the cover-domain pool before enabling rotation."
elif ! [[ "$ROTATION_INTERVAL" =~ ^[0-9]+$ ]]; then
  ROTATION_REASON="XRAY_ROTATE_HOURS must be an integer, got '${ROTATION_INTERVAL}'."
elif (( ROTATION_INTERVAL > 0 )); then
  cat > "$ROTATION_SERVICE_PATH" <<EOF
[Unit]
Description=Rotate Xray REALITY cover domain
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${SCRIPT_DIR}/rotate-reality-cover.sh
EOF

  cat > "$ROTATION_TIMER_PATH" <<EOF
[Unit]
Description=Rotate Xray REALITY cover domain every ${ROTATION_INTERVAL} hours

[Timer]
OnBootSec=1h
OnUnitActiveSec=${ROTATION_INTERVAL}h
RandomizedDelaySec=30m
Persistent=true
Unit=vpn-reality-cover-rotate.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now vpn-reality-cover-rotate.timer
  echo "REALITY cover rotation enabled every ${ROTATION_INTERVAL} hours."
else
  ROTATION_REASON="REALITY cover rotation is disabled (XRAY_ROTATE_HOURS=${ROTATION_INTERVAL})."
fi

if [[ -n "$ROTATION_REASON" ]]; then
  if systemctl list-unit-files vpn-reality-cover-rotate.timer --no-legend 2>/dev/null | grep -q '^vpn-reality-cover-rotate.timer'; then
    systemctl disable --now vpn-reality-cover-rotate.timer
  fi
  rm -f "$ROTATION_SERVICE_PATH" "$ROTATION_TIMER_PATH"
  systemctl daemon-reload
  echo "$ROTATION_REASON"
fi

echo ""
echo "Done."
echo "Credentials page: https://${DOMAIN}"
echo "Login: ${PAGE_USER} / ${PAGE_PASSWORD}"
