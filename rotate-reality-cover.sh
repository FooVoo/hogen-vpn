#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
WEBROOT="${WEBROOT:-/var/www/vpn}"

[[ -f "$ENV_FILE" ]] || { echo "ERROR: .env not found — run generate-secrets.sh first"; exit 1; }

set -a; source "$ENV_FILE"; set +a

[[ -n "${XRAY_COVER_DOMAINS:-}" ]] || { echo "ERROR: XRAY_COVER_DOMAINS is missing"; exit 1; }
[[ -n "${XRAY_UUID:-}" ]] || { echo "ERROR: XRAY_UUID is missing"; exit 1; }
[[ -n "${XRAY_PRIVATE_KEY:-}" ]] || { echo "ERROR: XRAY_PRIVATE_KEY is missing"; exit 1; }
[[ -n "${XRAY_PUBLIC_KEY:-}" ]] || { echo "ERROR: XRAY_PUBLIC_KEY is missing"; exit 1; }
[[ -n "${XRAY_SHORT_ID:-}" ]] || { echo "ERROR: XRAY_SHORT_ID is missing"; exit 1; }
[[ -n "${SERVER_IP:-}" ]] || { echo "ERROR: SERVER_IP is missing"; exit 1; }
[[ -n "${MTG_SECRET:-}" ]] || { echo "ERROR: MTG_SECRET is missing"; exit 1; }
[[ -n "${MTG_PORT:-}" ]] || { echo "ERROR: MTG_PORT is missing"; exit 1; }
[[ -n "${MTG_LINK:-}" ]] || { echo "ERROR: MTG_LINK is missing"; exit 1; }
[[ -n "${PAGE_USER:-}" ]] || { echo "ERROR: PAGE_USER is missing"; exit 1; }
[[ -n "${PAGE_PASSWORD:-}" ]] || { echo "ERROR: PAGE_PASSWORD is missing"; exit 1; }
XRAY_ROTATE_HOURS="${XRAY_ROTATE_HOURS:-2}"

IFS=',' read -r -a COVER_DOMAIN_POOL <<< "$XRAY_COVER_DOMAINS"
ROTATABLE_DOMAINS=()
for COVER_DOMAIN in "${COVER_DOMAIN_POOL[@]}"; do
  [[ -n "$COVER_DOMAIN" ]] || continue
  ROTATABLE_DOMAINS+=("$COVER_DOMAIN")
done

if (( ${#ROTATABLE_DOMAINS[@]} < 2 )); then
  echo "ERROR: need at least two cover domains to rotate"
  exit 1
fi

CURRENT_DOMAIN="${XRAY_SNI}"
CANDIDATES=()
for CANDIDATE in "${ROTATABLE_DOMAINS[@]}"; do
  [[ "$CANDIDATE" != "$CURRENT_DOMAIN" ]] && CANDIDATES+=("$CANDIDATE")
done

# Shuffle candidates so each run tries a different order
SHUFFLED=()
while (( ${#CANDIDATES[@]} > 0 )); do
  IDX=$(( RANDOM % ${#CANDIDATES[@]} ))
  SHUFFLED+=("${CANDIDATES[$IDX]}")
  CANDIDATES=("${CANDIDATES[@]:0:$IDX}" "${CANDIDATES[@]:$((IDX+1))}")
done

# Pick the first candidate that passes a TLS handshake on :443
# Tries TLS 1.3 first; falls back to any TLS if curl/openssl doesn't support 1.3
check_domain_tls() {
  local domain="$1"
  # Prefer TLS 1.3 check (works on Linux with OpenSSL 1.1.1+)
  if curl --silent --max-time 5 --head "https://${domain}/" \
    --tlsv1.3 -o /dev/null 2>/dev/null; then
    return 0
  fi
  # Fallback: any successful TLS handshake (covers older curl/LibreSSL)
  curl --silent --max-time 5 --head "https://${domain}/" \
    -o /dev/null 2>/dev/null
}

NEXT_DOMAIN=""
FAILED_DOMAINS=()
for CANDIDATE in "${SHUFFLED[@]}"; do
  if check_domain_tls "$CANDIDATE"; then
    NEXT_DOMAIN="$CANDIDATE"
    break
  fi
  FAILED_DOMAINS+=("$CANDIDATE")
done

if [[ -n "${FAILED_DOMAINS[*]:-}" ]]; then
  echo "WARNING: TLS check failed for: ${FAILED_DOMAINS[*]}"
fi

if [[ -z "$NEXT_DOMAIN" ]]; then
  echo "ERROR: no reachable cover domain found — keeping current domain ${CURRENT_DOMAIN}"
  exit 1
fi

XRAY_SNI="$NEXT_DOMAIN"
XRAY_DEST="${XRAY_SNI}:443"
VLESS_URI="vless://${XRAY_UUID}@${SERVER_IP}:8443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${XRAY_SNI}&fp=chrome&pbk=${XRAY_PUBLIC_KEY}&sid=${XRAY_SHORT_ID}&type=tcp#VPN"

TMP_ENV="$(mktemp)"
chmod 600 "$TMP_ENV"
trap 'rm -f "$TMP_ENV"' EXIT
cat > "$TMP_ENV" <<EOF
SERVER_IP=${SERVER_IP}

MTG_SECRET=${MTG_SECRET}
MTG_PORT=${MTG_PORT}
MTG_LINK="${MTG_LINK}"

XRAY_UUID=${XRAY_UUID}
XRAY_PRIVATE_KEY=${XRAY_PRIVATE_KEY}
XRAY_PUBLIC_KEY=${XRAY_PUBLIC_KEY}
XRAY_SHORT_ID=${XRAY_SHORT_ID}
XRAY_SNI=${XRAY_SNI}
XRAY_DEST=${XRAY_DEST}
XRAY_COVER_DOMAINS=${XRAY_COVER_DOMAINS}
XRAY_ROTATE_HOURS=${XRAY_ROTATE_HOURS}
VLESS_URI="${VLESS_URI}"

PAGE_USER=${PAGE_USER}
PAGE_PASSWORD=${PAGE_PASSWORD}
EOF
mv "$TMP_ENV" "$ENV_FILE"

"$SCRIPT_DIR/render-xray-config.sh"
"$SCRIPT_DIR/render-credentials-page.sh" "$WEBROOT"

docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d --force-recreate xray >/dev/null

echo "Rotated REALITY cover domain: ${CURRENT_DOMAIN} -> ${XRAY_SNI}"
