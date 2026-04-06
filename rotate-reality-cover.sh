#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
WEBROOT="${WEBROOT:-/var/www/vpn}"

# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

[[ -f "$ENV_FILE" ]] || { log_error ".env not found — run generate-secrets.sh first"; exit 1; }

set -a; source "$ENV_FILE"; set +a

[[ -n "${XRAY_COVER_DOMAINS:-}" ]] || { log_error "XRAY_COVER_DOMAINS is missing"; exit 1; }
[[ -n "${XRAY_UUID:-}" ]]        || { log_error "XRAY_UUID is missing"; exit 1; }
[[ -n "${XRAY_PRIVATE_KEY:-}" ]] || { log_error "XRAY_PRIVATE_KEY is missing"; exit 1; }
[[ -n "${XRAY_PUBLIC_KEY:-}" ]]  || { log_error "XRAY_PUBLIC_KEY is missing"; exit 1; }
[[ -n "${XRAY_SHORT_ID:-}" ]]    || { log_error "XRAY_SHORT_ID is missing"; exit 1; }
[[ -n "${SERVER_IP:-}" ]]        || { log_error "SERVER_IP is missing"; exit 1; }
[[ -n "${MTG_SECRET:-}" ]]       || { log_error "MTG_SECRET is missing"; exit 1; }
[[ -n "${MTG_PORT:-}" ]]         || { log_error "MTG_PORT is missing"; exit 1; }
[[ -n "${MTG_LINK:-}" ]]         || { log_error "MTG_LINK is missing"; exit 1; }
[[ -n "${SS_METHOD:-}" ]]        || { log_error "SS_METHOD is missing"; exit 1; }
[[ -n "${SS_PORT:-}" ]]          || { log_error "SS_PORT is missing"; exit 1; }
[[ -n "${SS_PASSWORD:-}" ]]      || { log_error "SS_PASSWORD is missing"; exit 1; }
[[ -n "${SS_URI:-}" ]]           || { log_error "SS_URI is missing"; exit 1; }
[[ -n "${IKE_PSK:-}" ]]          || { log_error "IKE_PSK is missing"; exit 1; }
[[ -n "${IKE_USER:-}" ]]         || { log_error "IKE_USER is missing"; exit 1; }
[[ -n "${IKE_PASSWORD:-}" ]]     || { log_error "IKE_PASSWORD is missing"; exit 1; }
[[ -n "${PAGE_TOKEN:-}" ]]       || { log_error "PAGE_TOKEN is missing"; exit 1; }
XRAY_ROTATE_MINS="${XRAY_ROTATE_MINS:-30}"
MTG_ROTATE_MINS="${MTG_ROTATE_MINS:-30}"

# MTProxy fingerprint vars — fall back to the REALITY pool so old deployments
# that pre-date MTG_COVER_DOMAINS still rotate correctly after an upgrade.
MTG_COVER_DOMAINS="${MTG_COVER_DOMAINS:-$XRAY_COVER_DOMAINS}"
MTG_COVER_DOMAIN="${MTG_COVER_DOMAIN:-$XRAY_SNI}"

IFS=',' read -r -a COVER_DOMAIN_POOL <<< "$XRAY_COVER_DOMAINS"
ROTATABLE_DOMAINS=()
for COVER_DOMAIN in "${COVER_DOMAIN_POOL[@]}"; do
  [[ -n "$COVER_DOMAIN" ]] || continue
  ROTATABLE_DOMAINS+=("$COVER_DOMAIN")
done

if (( ${#ROTATABLE_DOMAINS[@]} < 2 )); then
  log_error "need at least two cover domains to rotate"
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
  log_warn "TLS check failed for: ${FAILED_DOMAINS[*]}"
fi

if [[ -z "$NEXT_DOMAIN" ]]; then
  log_error "no reachable cover domain found — keeping current domain ${CURRENT_DOMAIN}"
  exit 1
fi

XRAY_SNI="$NEXT_DOMAIN"
XRAY_DEST="${XRAY_SNI}:443"
VLESS_URI="vless://${XRAY_UUID}@${SERVER_IP}:8443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${XRAY_SNI}&fp=chrome&pbk=${XRAY_PUBLIC_KEY}&sid=${XRAY_SHORT_ID}&type=tcp#VPN"

# --- MTProxy FakeTLS fingerprint rotation ---
CURRENT_MTG_DOMAIN="$MTG_COVER_DOMAIN"
IFS=',' read -r -a MTG_DOMAIN_POOL <<< "$MTG_COVER_DOMAINS"
# Prefer a domain that differs from both the current MTG domain and the new
# REALITY SNI to keep the two fingerprints independent.
MTG_CANDIDATES=()
for D in "${MTG_DOMAIN_POOL[@]}"; do
  [[ -n "$D" && "$D" != "$CURRENT_MTG_DOMAIN" && "$D" != "$XRAY_SNI" ]] && MTG_CANDIDATES+=("$D")
done
# Fall back: allow the REALITY domain if no other candidates remain
if (( ${#MTG_CANDIDATES[@]} == 0 )); then
  for D in "${MTG_DOMAIN_POOL[@]}"; do
    [[ -n "$D" && "$D" != "$CURRENT_MTG_DOMAIN" ]] && MTG_CANDIDATES+=("$D")
  done
fi
if (( ${#MTG_CANDIDATES[@]} > 0 )); then
  NEXT_MTG_DOMAIN="${MTG_CANDIDATES[$RANDOM % ${#MTG_CANDIDATES[@]}]}"
else
  NEXT_MTG_DOMAIN="$CURRENT_MTG_DOMAIN"
fi
MTG_SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret "$NEXT_MTG_DOMAIN")
[[ "$MTG_SECRET" =~ ^ee[0-9a-f]{32,}$ ]] || [[ "$MTG_SECRET" =~ ^[A-Za-z0-9_-]{32,}=*$ ]] || {
  log_error "MTProxy secret has unexpected format: '${MTG_SECRET:0:40}'"
  exit 1
}
MTG_COVER_DOMAIN="$NEXT_MTG_DOMAIN"
MTG_LINK="https://t.me/proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${MTG_SECRET}"
mkdir -p "${SCRIPT_DIR}/mtg"
cat > "${SCRIPT_DIR}/mtg/config.toml" <<EOF
secret = "${MTG_SECRET}"
bind-to = "0.0.0.0:3128"
EOF
chmod 600 "${SCRIPT_DIR}/mtg/config.toml"

TMP_ENV="$(mktemp)"
chmod 600 "$TMP_ENV"
trap 'rm -f "$TMP_ENV"' EXIT
cat > "$TMP_ENV" <<EOF
SERVER_IP=${SERVER_IP}

MTG_SECRET=${MTG_SECRET}
MTG_PORT=${MTG_PORT}
MTG_COVER_DOMAIN=${MTG_COVER_DOMAIN}
MTG_COVER_DOMAINS=${MTG_COVER_DOMAINS}
MTG_LINK="${MTG_LINK}"
MTG_ROTATE_MINS=${MTG_ROTATE_MINS}

XRAY_UUID=${XRAY_UUID}
XRAY_PRIVATE_KEY=${XRAY_PRIVATE_KEY}
XRAY_PUBLIC_KEY=${XRAY_PUBLIC_KEY}
XRAY_SHORT_ID=${XRAY_SHORT_ID}
XRAY_SNI=${XRAY_SNI}
XRAY_DEST=${XRAY_DEST}
XRAY_COVER_DOMAINS=${XRAY_COVER_DOMAINS}
XRAY_ROTATE_MINS=${XRAY_ROTATE_MINS}
VLESS_URI="${VLESS_URI}"

SS_METHOD=${SS_METHOD}
SS_PORT=${SS_PORT}
SS_PASSWORD="${SS_PASSWORD}"
SS_URI="${SS_URI}"

IKE_PSK="${IKE_PSK}"
IKE_USER=${IKE_USER}
IKE_PASSWORD=${IKE_PASSWORD}

PAGE_TOKEN=${PAGE_TOKEN}

CREDENTIALS_DOMAIN=${CREDENTIALS_DOMAIN:-}
CREDENTIALS_WEBROOT=${CREDENTIALS_WEBROOT:-/var/www/vpn}
NGINX_VHOST_PATH=${NGINX_VHOST_PATH:-}
EOF
mv "$TMP_ENV" "$ENV_FILE"

"$SCRIPT_DIR/render-xray-config.sh"
"$SCRIPT_DIR/render-credentials-page.sh" "$WEBROOT"

docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d --force-recreate xray mtg >/dev/null

date '+%Y-%m-%d %H:%M %Z' > "${SCRIPT_DIR}/.last_xray_rotation"
date '+%Y-%m-%d %H:%M %Z' > "${SCRIPT_DIR}/.last_mtg_rotation"

# Increment rotation counters in Netdata StatsD.
log_metric "rotations.xray" 1 c
log_metric "rotations.mtg"  1 c

log_ok "REALITY cover domain: ${CURRENT_DOMAIN} → ${XRAY_SNI}"
log_ok "MTProxy fingerprint:  ${CURRENT_MTG_DOMAIN} → ${MTG_COVER_DOMAIN}"
