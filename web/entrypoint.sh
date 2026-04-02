#!/bin/sh
set -e

# Generate htpasswd file (openssl is available in nginx:alpine)
printf '%s:%s\n' "$PAGE_USER" "$(openssl passwd -apr1 "$PAGE_PASSWORD")" \
  > /etc/nginx/htpasswd

# Substitute env vars in HTML template
# List variables explicitly to avoid clobbering nginx's own $uri / $host etc.
envsubst '${SERVER_IP}${MTG_SECRET}${MTG_LINK}${XRAY_UUID}${XRAY_PUBLIC_KEY}${XRAY_SHORT_ID}${XRAY_SNI}${VLESS_URI}' \
  < /web/index.html.template \
  > /usr/share/nginx/html/index.html

# Install nginx config
cp /web/nginx.conf /etc/nginx/conf.d/default.conf

exec nginx -g 'daemon off;'
