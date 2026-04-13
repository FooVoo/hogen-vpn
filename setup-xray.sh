#!/usr/bin/env bash
# setup-xray.sh — generate VLESS+Reality and Shadowsocks 2022 credentials.
#
# Writes:
#   xray/config.json        — Xray server config (via render-xray-config.sh)
#   .env                    — XRAY_* and SS_* variables
#
# Usage:
#   ./setup-xray.sh <SERVER_IP> [REALITY_COVER_DOMAIN]
#   ./setup-xray.sh                          # reads SERVER_IP from existing .env
#   ./setup-xray.sh --force                  # regenerate even if already configured
#   ./setup-xray.sh 1.2.3.4 github.com
#   ./setup-xray.sh --server-ip=1.2.3.4 --cover-domain=github.com
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/env.sh
source "${SCRIPT_DIR}/lib/env.sh"
# shellcheck source=lib/cover-domains.sh
source "${SCRIPT_DIR}/lib/cover-domains.sh"

FORCE=false
SERVER_IP=""
REALITY_COVER_DOMAIN=""

for arg in "$@"; do
  case "$arg" in
    --force)            FORCE=true ;;
    --server-ip=*)      SERVER_IP="${arg#--server-ip=}" ;;
    --cover-domain=*)   REALITY_COVER_DOMAIN="${arg#--cover-domain=}" ;;
    -*)  log_error "Unknown option: $arg"; exit 1 ;;
    *)
      if   [[ -z "$SERVER_IP" ]];             then SERVER_IP="$arg"
      elif [[ -z "$REALITY_COVER_DOMAIN" ]];  then REALITY_COVER_DOMAIN="$arg"
      fi
      ;;
  esac
done

# Load SERVER_IP from .env if not provided on the command line
if [[ -z "$SERVER_IP" ]] && [[ -f "${SCRIPT_DIR}/.env" ]]; then
  SERVER_IP=$(grep -E '^SERVER_IP=' "${SCRIPT_DIR}/.env" | head -1 | cut -d= -f2- | tr -d '"' || true)
fi
[[ -n "$SERVER_IP" ]] || {
  log_error "SERVER_IP is required."
  echo "Usage: $0 <SERVER_IP> [REALITY_COVER_DOMAIN]" >&2
  exit 1
}

# Skip if already configured (unless --force)
if [[ "$FORCE" == false ]] && [[ -f "${SCRIPT_DIR}/.env" ]] \
    && grep -qE '^XRAY_PRIVATE_KEY=' "${SCRIPT_DIR}/.env"; then
  log_info "VLESS/Xray already configured. Use --force to regenerate."
  exit 0
fi

command -v docker >/dev/null 2>&1 || { log_error "docker is not installed"; exit 1; }
command -v openssl >/dev/null 2>&1 || { log_error "openssl is not installed"; exit 1; }

# ── VLESS + REALITY credentials ───────────────────────────────────────────────

log_info "Generating VLESS+Reality credentials..."

if [[ -f /proc/sys/kernel/random/uuid ]]; then
  XRAY_UUID=$(cat /proc/sys/kernel/random/uuid)
else
  XRAY_UUID=$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null \
    || uuidgen \
    || { log_error "Cannot generate UUID — install python3 or uuidgen"; exit 1; })
fi

XRAY_KEYPAIR=$(docker run --rm ghcr.io/xtls/xray-core:26.3.27 x25519)
XRAY_PRIVATE_KEY=$(echo "$XRAY_KEYPAIR" | awk -F': *' '/^PrivateKey:|^Private key:/{print $2; exit}')
XRAY_PUBLIC_KEY=$(echo  "$XRAY_KEYPAIR" | awk -F': *' '/Password \(PublicKey\):|^Public key:/{print $2; exit}')
XRAY_SHORT_ID=$(openssl rand -hex 8)

# Cover domain selection — prepend user-supplied domain to pool if not already present
if [[ -n "$REALITY_COVER_DOMAIN" ]]; then
  XRAY_SNI="${REALITY_COVER_DOMAIN#https://}"
  XRAY_SNI="${XRAY_SNI#http://}"
  XRAY_SNI="${XRAY_SNI%%/*}"
  XRAY_SNI="${XRAY_SNI%%:*}"
  DOMAIN_IN_POOL=false
  for _D in "${COVER_DOMAINS[@]}"; do
    [[ "$_D" == "$XRAY_SNI" ]] && { DOMAIN_IN_POOL=true; break; }
  done
  [[ "$DOMAIN_IN_POOL" == true ]] || COVER_DOMAINS=("$XRAY_SNI" "${COVER_DOMAINS[@]}")
else
  XRAY_SNI="${COVER_DOMAINS[$RANDOM % ${#COVER_DOMAINS[@]}]}"
fi

[[ -n "$XRAY_SNI" && -n "$XRAY_PRIVATE_KEY" && -n "$XRAY_PUBLIC_KEY" ]] || {
  log_error "Failed to generate REALITY credentials"
  exit 1
}

XRAY_COVER_DOMAINS=$(IFS=,; echo "${COVER_DOMAINS[*]}")
XRAY_ROTATE_MINS=120
XRAY_DEST="${XRAY_SNI}:443"
VLESS_URI="vless://${XRAY_UUID}@${SERVER_IP}:8443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${XRAY_SNI}&fp=chrome&pbk=${XRAY_PUBLIC_KEY}&sid=${XRAY_SHORT_ID}&type=tcp#VPN"

# ── Shadowsocks 2022 credentials ─────────────────────────────────────────────

log_info "Generating Shadowsocks 2022 credentials..."

SS_METHOD="2022-blake3-aes-256-gcm"
SS_PORT=8388
SS_PASSWORD=$(openssl rand -base64 32 | tr -d '\n')
SS_USERINFO=$(printf '%s:%s' "$SS_METHOD" "$SS_PASSWORD" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
SS_URI="ss://${SS_USERINFO}@${SERVER_IP}:${SS_PORT}#SS-VPN"

# ── Write to .env ─────────────────────────────────────────────────────────────

env_write SERVER_IP         "$SERVER_IP"
env_write XRAY_UUID         "$XRAY_UUID"
env_write XRAY_PRIVATE_KEY  "$XRAY_PRIVATE_KEY"
env_write XRAY_PUBLIC_KEY   "$XRAY_PUBLIC_KEY"
env_write XRAY_SHORT_ID     "$XRAY_SHORT_ID"
env_write XRAY_SNI          "$XRAY_SNI"
env_write XRAY_DEST         "$XRAY_DEST"
env_write XRAY_COVER_DOMAINS "$XRAY_COVER_DOMAINS"
env_write XRAY_ROTATE_MINS  "$XRAY_ROTATE_MINS"
env_write VLESS_URI         "$VLESS_URI"
env_write SS_METHOD         "$SS_METHOD"
env_write SS_PORT           "$SS_PORT"
env_write SS_PASSWORD       "$SS_PASSWORD"
env_write SS_URI            "$SS_URI"

# ── Generate xray/config.json ─────────────────────────────────────────────────

"${SCRIPT_DIR}/render-xray-config.sh"

log_ok "VLESS+Reality+Shadowsocks configured (SNI: ${XRAY_SNI})"
