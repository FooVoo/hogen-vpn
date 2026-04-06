#!/usr/bin/env bash
# generate-secrets.sh — generate all VPN credentials in one shot.
#
# This is the master orchestrator. Each protocol's credential generation lives
# in its own script (setup-xray.sh, setup-mtg.sh, setup-ikev2.sh,
# setup-wireguard.sh) and can also be run standalone to regenerate a single
# protocol without touching the others.
#
# Usage:
#   ./generate-secrets.sh <SERVER_IP> [REALITY_COVER_DOMAIN] [CREDENTIALS_DOMAIN]
#
# To regenerate a single protocol after initial setup:
#   ./setup-wireguard.sh --force
#   ./setup-xray.sh --force
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

SERVER_IP="${1:-}"
if [[ -z "$SERVER_IP" ]]; then
  echo "Usage: $0 <SERVER_IP> [REALITY_COVER_DOMAIN] [CREDENTIALS_DOMAIN]"
  echo "Example: $0 1.2.3.4"
  echo "Example: $0 1.2.3.4 github.com vpn.example.com"
  exit 1
fi

REALITY_COVER_DOMAIN="${2:-}"
CREDENTIALS_DOMAIN="${3:-}"

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  log_error ".env already exists. Delete it first to regenerate all secrets."
  log_info  "To regenerate a single protocol, run its setup script with --force:"
  log_info  "  ./setup-xray.sh --force | ./setup-mtg.sh --force | ./setup-ikev2.sh --force | ./setup-wireguard.sh --force"
  exit 1
fi

command -v docker  >/dev/null 2>&1 || { log_error "docker is not installed";  exit 1; }
command -v openssl >/dev/null 2>&1 || { log_error "openssl is not installed"; exit 1; }

# ── Pull all runtime images upfront ──────────────────────────────────────────
# Sub-scripts pull only the images they use for key generation; pulling all
# runtime images here ensures 'docker compose up' works immediately after.

log_info "Pulling Docker images..."
docker pull --quiet nineseconds/mtg:2              >/dev/null
docker pull --quiet ghcr.io/xtls/xray-core:26.3.27 >/dev/null
docker pull --quiet hwdsl2/ipsec-vpn-server:latest  >/dev/null
docker pull --quiet lscr.io/linuxserver/wireguard:latest >/dev/null
docker pull --quiet alpine:3                        >/dev/null

# ── Seed .env with common vars before calling sub-scripts ────────────────────

printf 'SERVER_IP=%s\n'            "$SERVER_IP"         > "${SCRIPT_DIR}/.env"
printf 'CREDENTIALS_DOMAIN=%s\n'   "$CREDENTIALS_DOMAIN" >> "${SCRIPT_DIR}/.env"
printf 'CREDENTIALS_WEBROOT=%s\n'  "/var/www/vpn"        >> "${SCRIPT_DIR}/.env"
chmod 600 "${SCRIPT_DIR}/.env"

# ── Per-protocol credential generation ───────────────────────────────────────
# Run Xray first so MTProxy can reuse its cover-domain pool.

"${SCRIPT_DIR}/setup-xray.sh" \
  ${REALITY_COVER_DOMAIN:+"--cover-domain=${REALITY_COVER_DOMAIN}"}

"${SCRIPT_DIR}/setup-mtg.sh"

"${SCRIPT_DIR}/setup-ikev2.sh"

"${SCRIPT_DIR}/setup-wireguard.sh"

# ── Page token (written last; only needed by setup-nginx.sh) ─────────────────

PAGE_TOKEN=$(openssl rand -hex 16)
printf 'PAGE_TOKEN=%s\n' "$PAGE_TOKEN" >> "${SCRIPT_DIR}/.env"

# ── Summary ───────────────────────────────────────────────────────────────────

set -a; source "${SCRIPT_DIR}/.env"; set +a

log_ok ""
log_ok "Done. Files written:"
log_ok "  .env                    — all credentials"
log_ok "  mtg/config.toml         — MTProxy config"
log_ok "  xray/config.json        — VLESS + Shadowsocks config"
log_ok "  wireguard/wg0.conf      — WireGuard server config"
log_ok "  wireguard/peer1.conf    — WireGuard client config"
log_ok ""
log_ok "REALITY cover domain:  ${XRAY_SNI}"
log_ok "MTProxy cover domain:  ${MTG_COVER_DOMAIN}"
log_ok "Shadowsocks method:    ${SS_METHOD}"
log_ok "IKEv2 user:            ${IKE_USER}"
log_ok "WireGuard client IP:   ${WG_CLIENT_IP}"
log_ok ""
log_ok "Credentials page token:  ${PAGE_TOKEN}"
log_ok "(Share URL: https://<CREDENTIALS_DOMAIN>/${PAGE_TOKEN}/)"
log_ok ""
log_info "Next: ./setup-nginx.sh && docker compose up -d"
