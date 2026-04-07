#!/usr/bin/env bash
# Run on the server after generate-secrets.sh.
# Sets up nginx vhost for the credentials page + SSL + firewall rules.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

[[ $EUID -eq 0 ]] || { log_error "Run as root"; exit 1; }
[[ -f "$SCRIPT_DIR/.env" ]] || { log_error ".env not found — run generate-secrets.sh first"; exit 1; }

# Load credentials
set -a; source "$SCRIPT_DIR/.env"; set +a

[[ -n "${CREDENTIALS_DOMAIN:-}" ]] || { log_error "CREDENTIALS_DOMAIN is missing in .env"; exit 1; }
[[ -n "${PAGE_TOKEN:-}" ]]        || { log_error "PAGE_TOKEN is missing — re-run generate-secrets.sh"; exit 1; }

DOMAIN="${CREDENTIALS_DOMAIN}"
WEBROOT="${CREDENTIALS_WEBROOT:-/var/www/vpn}"
VHOST_PATH="${NGINX_VHOST_PATH:-/etc/nginx/sites-available/vpn}"

# Install tools
apt-get update -q
apt-get install -y --quiet certbot python3-certbot-nginx gettext-base fail2ban build-essential

# Persist host IP forwarding — required for IKEv2 traffic routing.
# Docker enables ip_forward at runtime but doesn't persist it; without this
# a reboot before Docker starts leaves forwarding off and VPN traffic is dropped.
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-hogen-vpn.conf
sysctl -w net.ipv4.ip_forward=1

# Harden firewall defaults before opening specific ports.
# Explicit defaults make this script idempotent regardless of any prior UFW state
# (e.g., a server that previously ran 'ufw default allow incoming').
ufw default deny incoming
ufw default allow outgoing

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
ufw allow 51820/udp comment "WireGuard"
ufw --force enable

# Generate HTML credentials page (written to $WEBROOT/$PAGE_TOKEN/)
"$SCRIPT_DIR/render-credentials-page.sh" "$WEBROOT"

# Install nginx rate limiting zone first — vhost references zone=vpn_auth
# so this must be in place before the first nginx -t
cp "$SCRIPT_DIR/web/nginx-ratelimit.conf"       /etc/nginx/conf.d/vpn-ratelimit.conf
cp "$SCRIPT_DIR/web/nginx-netdata-proxy.conf"   /etc/nginx/conf.d/vpn-netdata-proxy.conf

# Generate basic auth credentials for the Netdata dashboard.
# Username: admin  Password: PAGE_TOKEN
# openssl passwd -apr1 produces an Apache MD5 hash accepted by nginx.
HTPASSWD_HASH=$(openssl passwd -apr1 "${PAGE_TOKEN}")
printf 'admin:%s\n' "$HTPASSWD_HASH" > /etc/nginx/.htpasswd-netdata
chmod 640 /etc/nginx/.htpasswd-netdata
chown root:www-data /etc/nginx/.htpasswd-netdata

# Install local-only health-check listener (127.0.0.1:9000 — SSH access only)
export WEBROOT
envsubst '${WEBROOT}' \
  < "$SCRIPT_DIR/web/nginx-check-local.conf.template" \
  > /etc/nginx/conf.d/vpn-check-local.conf

# Install nginx vhost (render template with env vars)
export CREDENTIALS_DOMAIN WEBROOT
envsubst '${CREDENTIALS_DOMAIN}${WEBROOT}${PAGE_TOKEN}' \
  < "$SCRIPT_DIR/web/nginx-vhost.conf.template" \
  > "$VHOST_PATH"
nginx -t
ln -sf "$VHOST_PATH" /etc/nginx/sites-enabled/vpn
systemctl reload nginx

# Get SSL certificate (certbot will update the vhost automatically)
# Set LETSENCRYPT_EMAIL in .env or environment to receive expiry notifications.
if [[ -n "${LETSENCRYPT_EMAIL:-}" ]]; then
  CERTBOT_EMAIL_ARGS=(--email "$LETSENCRYPT_EMAIL" --no-eff-email)
else
  log_warn "LETSENCRYPT_EMAIL not set — certificate expiry notifications disabled"
  CERTBOT_EMAIL_ARGS=(--register-unsafely-without-email)
fi
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
  "${CERTBOT_EMAIL_ARGS[@]}" --redirect

# Configure and enable fail2ban
mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d
cp "$SCRIPT_DIR/fail2ban/jail.d/hogen-vpn.conf"        /etc/fail2ban/jail.d/hogen-vpn.conf
cp "$SCRIPT_DIR/fail2ban/filter.d/nginx-path-probe.conf" /etc/fail2ban/filter.d/nginx-path-probe.conf
systemctl enable --now fail2ban
fail2ban-client reload || true

# Install Docker Compose auto-start service
command -v docker >/dev/null || { log_error "docker not found in PATH — install Docker Engine first"; exit 1; }
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
log_info "Docker stack auto-start enabled (hogen-vpn.service)."

ROTATION_SERVICE_PATH="/etc/systemd/system/vpn-reality-cover-rotate.service"
ROTATION_TIMER_PATH="/etc/systemd/system/vpn-reality-cover-rotate.timer"
ROTATION_INTERVAL="${XRAY_ROTATE_MINS:-0}"
ROTATION_REASON=""

if [[ -z "${XRAY_COVER_DOMAINS:-}" ]]; then
  ROTATION_REASON="XRAY_COVER_DOMAINS is missing in .env. Regenerate secrets or add the cover-domain pool before enabling rotation."
elif ! [[ "$ROTATION_INTERVAL" =~ ^[0-9]+$ ]]; then
  ROTATION_REASON="XRAY_ROTATE_MINS must be an integer, got '${ROTATION_INTERVAL}'."
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
TimeoutStartSec=120
EOF

  cat > "$ROTATION_TIMER_PATH" <<EOF
[Unit]
Description=Rotate Xray REALITY cover domain every ${ROTATION_INTERVAL} minutes

[Timer]
OnBootSec=15m
OnUnitActiveSec=${ROTATION_INTERVAL}min
RandomizedDelaySec=3min
Persistent=true
Unit=vpn-reality-cover-rotate.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now vpn-reality-cover-rotate.timer
  log_ok "REALITY cover rotation enabled every ${ROTATION_INTERVAL} minutes."
else
  ROTATION_REASON="REALITY cover rotation is disabled (XRAY_ROTATE_MINS=${ROTATION_INTERVAL})."
fi

if [[ -n "$ROTATION_REASON" ]]; then
  if systemctl list-unit-files vpn-reality-cover-rotate.timer --no-legend 2>/dev/null | grep -q '^vpn-reality-cover-rotate.timer'; then
    systemctl disable --now vpn-reality-cover-rotate.timer
  fi
  rm -f "$ROTATION_SERVICE_PATH" "$ROTATION_TIMER_PATH"
  systemctl daemon-reload
  log_warn "$ROTATION_REASON"
fi

# --- MTProxy rotation timer ---
MTG_SERVICE_PATH="/etc/systemd/system/vpn-mtg-rotate.service"
MTG_TIMER_PATH="/etc/systemd/system/vpn-mtg-rotate.timer"
MTG_INTERVAL="${MTG_ROTATE_MINS:-0}"
MTG_REASON=""

if [[ -z "${MTG_COVER_DOMAINS:-}" ]]; then
  MTG_REASON="MTG_COVER_DOMAINS is missing in .env. Regenerate secrets before enabling MTProxy rotation."
elif ! [[ "$MTG_INTERVAL" =~ ^[0-9]+$ ]]; then
  MTG_REASON="MTG_ROTATE_MINS must be an integer, got '${MTG_INTERVAL}'."
elif (( MTG_INTERVAL > 0 )); then
  cat > "$MTG_SERVICE_PATH" <<EOF
[Unit]
Description=Rotate MTProxy FakeTLS cover domain
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${SCRIPT_DIR}/rotate-mtg-cover.sh
TimeoutStartSec=120
EOF

  cat > "$MTG_TIMER_PATH" <<EOF
[Unit]
Description=Rotate MTProxy FakeTLS cover domain every ${MTG_INTERVAL} minutes

[Timer]
OnBootSec=15m
OnUnitActiveSec=${MTG_INTERVAL}min
RandomizedDelaySec=3min
Persistent=true
Unit=vpn-mtg-rotate.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now vpn-mtg-rotate.timer
  log_ok "MTProxy cover rotation enabled every ${MTG_INTERVAL} minutes."
else
  MTG_REASON="MTProxy cover rotation is disabled (MTG_ROTATE_MINS=${MTG_INTERVAL})."
fi

if [[ -n "$MTG_REASON" ]]; then
  if systemctl list-unit-files vpn-mtg-rotate.timer --no-legend 2>/dev/null | grep -q '^vpn-mtg-rotate.timer'; then
    systemctl disable --now vpn-mtg-rotate.timer
  fi
  rm -f "$MTG_SERVICE_PATH" "$MTG_TIMER_PATH"
  systemctl daemon-reload
  log_warn "$MTG_REASON"
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
TimeoutStartSec=30
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
log_ok "Health-check monitoring enabled (vpn-health-check.timer)."

# --- Rust toolchain (for rotate-api) -----------------------------------------
# rotate-api is a compiled Rust binary; build it once during setup.
CARGO_BIN="${HOME}/.cargo/bin/cargo"
if ! command -v cargo >/dev/null 2>&1 && [[ ! -x "$CARGO_BIN" ]]; then
  log_info "Installing Rust toolchain via rustup..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --no-modify-path
  log_ok "Rust installed: $("${HOME}/.cargo/bin/rustc" --version)"
fi
export PATH="${HOME}/.cargo/bin:${PATH}"

log_info "Building rotate-api (cargo build --release)..."
(cd "${SCRIPT_DIR}/rotate-api" && cargo build --release --quiet)
log_ok "rotate-api binary built."

# --- Force-rotation API -------------------------------------------------------
# rotate-api (Rust binary) listens on 127.0.0.1:9001 and runs rotation scripts on demand.
ROTATE_API_SERVICE_PATH="/etc/systemd/system/vpn-rotate-api.service"
cat > "$ROTATE_API_SERVICE_PATH" <<EOF
[Unit]
Description=hogen-vpn on-demand rotation API
After=docker.service hogen-vpn.service
Wants=docker.service

[Service]
Type=simple
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${SCRIPT_DIR}/rotate-api/target/release/rotate-api
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now vpn-rotate-api.service
log_ok "Force-rotation API enabled (vpn-rotate-api.service on 127.0.0.1:9001)."

# --- Netdata monitoring -------------------------------------------------------
# Install Netdata (via apt; provides a stable, distro-maintained version).
if ! command -v netdata >/dev/null 2>&1; then
  log_info "Installing Netdata..."
  apt-get install -y --quiet netdata
fi

# The VPN charts.d plugin runs as the netdata user; it needs docker access.
if getent group docker >/dev/null 2>&1 && ! id -nG netdata 2>/dev/null | grep -qw docker; then
  usermod -aG docker netdata
  log_info "Added netdata to docker group."
fi

# Deploy charts.d plugin and health alerts.
NETDATA_CHARTS_DIR="${NETDATA_CHARTS_DIR:-/usr/lib/netdata/charts.d}"
NETDATA_HEALTH_DIR="${NETDATA_HEALTH_DIR:-/etc/netdata/health.d}"
mkdir -p "$NETDATA_CHARTS_DIR" "$NETDATA_HEALTH_DIR"

install -m 755 "${SCRIPT_DIR}/netdata/vpn.chart.sh" "${NETDATA_CHARTS_DIR}/vpn.chart.sh"
install -m 644 "${SCRIPT_DIR}/netdata/health.d/vpn.conf" "${NETDATA_HEALTH_DIR}/vpn.conf"

# Write VPN_DIR so the plugin knows where to read rotation timestamps.
mkdir -p /etc/netdata/charts.d
cat > /etc/netdata/charts.d/vpn.conf <<EOF
VPN_DIR=${SCRIPT_DIR}
EOF

systemctl restart netdata
log_ok "Netdata monitoring enabled (http://localhost:19999)."
log_info "Public dashboard: https://${DOMAIN}/net-data/  (user: admin  pass: PAGE_TOKEN)"
log_info "WGDashboard:      https://${DOMAIN}/wg-dash/   (nginx: admin/PAGE_TOKEN → wgd login: admin/admin, change on first login)"
log_info "View via CLI:     ./vpn-logs.sh --url"
systemctl reload nginx

log_ok ""
log_ok "Done."
log_ok "Credentials page: https://${DOMAIN}/${PAGE_TOKEN}/"
log_info "Status page (SSH): ssh user@${DOMAIN} curl -s http://127.0.0.1:9000/check/status.json"
log_info "Share the credentials URL — it is the only credential needed."
log_info ""
log_info "Container status:"
docker compose -f "${SCRIPT_DIR}/docker-compose.yml" ps
