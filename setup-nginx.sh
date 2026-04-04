#!/usr/bin/env bash
# Run on the server after generate-secrets.sh.
# Sets up nginx vhost for the credentials page + SSL + firewall rules.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
[[ -f "$SCRIPT_DIR/.env" ]] || { echo "ERROR: .env not found — run generate-secrets.sh first"; exit 1; }

# Load credentials
set -a; source "$SCRIPT_DIR/.env"; set +a

[[ -n "${CREDENTIALS_DOMAIN:-}" ]] || { echo "ERROR: CREDENTIALS_DOMAIN is missing in .env"; exit 1; }
[[ -n "${PAGE_TOKEN:-}" ]]        || { echo "ERROR: PAGE_TOKEN is missing — re-run generate-secrets.sh"; exit 1; }

DOMAIN="${CREDENTIALS_DOMAIN}"
WEBROOT="${CREDENTIALS_WEBROOT:-/var/www/vpn}"
VHOST_PATH="${NGINX_VHOST_PATH:-/etc/nginx/sites-available/vpn}"

# Install tools
apt-get install -y --quiet certbot python3-certbot-nginx gettext-base fail2ban

# Open firewall — SSH first to prevent lockout
ufw allow OpenSSH comment "SSH"
ufw allow 80/tcp   comment "HTTP"
ufw allow 443/tcp  comment "HTTPS"
ufw allow 2083/tcp comment "MTProxy"
ufw allow 8443/tcp comment "VLESS"
ufw allow 8388/tcp comment "Shadowsocks"
ufw allow 8388/udp comment "Shadowsocks"
ufw allow 500/udp  comment "IKEv2"
ufw allow 4500/udp comment "IKEv2 NAT-T"
ufw --force enable

# Generate HTML credentials page (written to $WEBROOT/$PAGE_TOKEN/)
"$SCRIPT_DIR/render-credentials-page.sh" "$WEBROOT"

# Install nginx rate limiting zone first — vhost references zone=vpn_auth
# so this must be in place before the first nginx -t
cp "$SCRIPT_DIR/web/nginx-ratelimit.conf" /etc/nginx/conf.d/vpn-ratelimit.conf

# Install nginx vhost (render template with env vars)
export CREDENTIALS_DOMAIN WEBROOT
envsubst '${CREDENTIALS_DOMAIN}${WEBROOT}' \
  < "$SCRIPT_DIR/web/nginx-vhost.conf.template" \
  > "$VHOST_PATH"
ln -sf "$VHOST_PATH" /etc/nginx/sites-enabled/vpn
nginx -t
systemctl reload nginx

# Get SSL certificate (certbot will update the vhost automatically)
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
  --register-unsafely-without-email --redirect

# Configure and enable fail2ban
mkdir -p /etc/fail2ban/jail.d
cp "$SCRIPT_DIR/fail2ban/jail.d/hogen-vpn.conf" /etc/fail2ban/jail.d/hogen-vpn.conf
systemctl enable --now fail2ban
fail2ban-client reload || true

# Install Docker Compose auto-start service
DOCKER_BIN="$(command -v docker)"
AUTOSTART_SERVICE_PATH="/etc/systemd/system/hogen-vpn.service"
cat > "$AUTOSTART_SERVICE_PATH" <<EOF
[Unit]
Description=hogen-vpn VPN stack (Docker Compose)
Documentation=file://${SCRIPT_DIR}/README.md
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${DOCKER_BIN} compose up -d --remove-orphans
ExecStop=${DOCKER_BIN} compose stop
TimeoutStartSec=120
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now hogen-vpn.service
echo "Docker stack auto-start enabled (hogen-vpn.service)."

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
OnBootSec=15m
OnUnitActiveSec=${ROTATION_INTERVAL}h
RandomizedDelaySec=10m
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

# Install health-check timer (generates /check status page every 60 s)
CHECK_SERVICE_PATH="/etc/systemd/system/vpn-health-check.service"
CHECK_TIMER_PATH="/etc/systemd/system/vpn-health-check.timer"

cat > "$CHECK_SERVICE_PATH" <<EOF
[Unit]
Description=hogen-vpn health-check status page
After=docker.service hogen-vpn.service
Wants=docker.service

[Service]
Type=oneshot
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${SCRIPT_DIR}/check.sh
EOF

cat > "$CHECK_TIMER_PATH" <<EOF
[Unit]
Description=Run hogen-vpn health-check every 60 seconds

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
RandomizedDelaySec=5s
Persistent=true
Unit=vpn-health-check.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now vpn-health-check.timer
# Run once immediately so /check is populated before first 60 s tick
"${SCRIPT_DIR}/check.sh" || true
echo "Health-check monitoring enabled (vpn-health-check.timer)."

echo ""
echo "Done."
echo "Credentials page: https://${DOMAIN}/${PAGE_TOKEN}/"
echo "Status page:       https://${DOMAIN}/check"
echo "Share the credentials URL — it is the only credential needed."
echo ""
echo "Container status:"
docker compose -f "${SCRIPT_DIR}/docker-compose.yml" ps
