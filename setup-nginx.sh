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
ufw allow 2083/tcp comment "MTProxy"
ufw allow 8443/tcp comment "VLESS"

# Generate HTML credentials page
mkdir -p "$WEBROOT"
envsubst '${SERVER_IP}${MTG_PORT}${MTG_SECRET}${MTG_LINK}${XRAY_UUID}${XRAY_PUBLIC_KEY}${XRAY_SHORT_ID}${XRAY_SNI}${VLESS_URI}' \
  < "$SCRIPT_DIR/web/index.html.template" \
  > "$WEBROOT/index.html"

# Generate htpasswd
printf '%s:%s\n' "$PAGE_USER" "$(openssl passwd -apr1 "$PAGE_PASSWORD")" \
  > /etc/nginx/htpasswd-vpn
chmod 644 /etc/nginx/htpasswd-vpn

# Install nginx vhost
cp "$SCRIPT_DIR/web/nginx-vhost.conf" "$VHOST_PATH"
ln -sf "$VHOST_PATH" /etc/nginx/sites-enabled/vpn
nginx -t
systemctl reload nginx

# Get SSL certificate (certbot will update the vhost automatically)
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
  --register-unsafely-without-email --redirect

echo ""
echo "Done."
echo "Credentials page: https://${DOMAIN}"
echo "Login: ${PAGE_USER} / ${PAGE_PASSWORD}"
