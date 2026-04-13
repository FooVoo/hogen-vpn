#!/usr/bin/env bash
# setup-mtg.sh — generate MTProxy (mtg v2) credentials and write mtg/config.toml.
#
# Writes:
#   mtg/config.toml         — MTProxy server config
#   .env                    — MTG_* variables
#
# Usage:
#   ./setup-mtg.sh <SERVER_IP>
#   ./setup-mtg.sh                    # reads SERVER_IP from existing .env
#   ./setup-mtg.sh --force            # regenerate even if already configured
#   ./setup-mtg.sh --server-ip=1.2.3.4
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

for arg in "$@"; do
  case "$arg" in
    --force)        FORCE=true ;;
    --server-ip=*)  SERVER_IP="${arg#--server-ip=}" ;;
    -*)  log_error "Unknown option: $arg"; exit 1 ;;
    *)
      [[ -z "$SERVER_IP" ]] && SERVER_IP="$arg"
      ;;
  esac
done

# Load SERVER_IP from .env if not provided on the command line
if [[ -z "$SERVER_IP" ]] && [[ -f "${SCRIPT_DIR}/.env" ]]; then
  SERVER_IP=$(grep -E '^SERVER_IP=' "${SCRIPT_DIR}/.env" | head -1 | cut -d= -f2- | tr -d '"' || true)
fi
[[ -n "$SERVER_IP" ]] || {
  log_error "SERVER_IP is required."
  echo "Usage: $0 <SERVER_IP>" >&2
  exit 1
}

# Skip if already configured (unless --force)
if [[ "$FORCE" == false ]] && [[ -f "${SCRIPT_DIR}/.env" ]] \
    && grep -qE '^MTG_SECRET=' "${SCRIPT_DIR}/.env"; then
  log_info "MTProxy already configured. Use --force to regenerate."
  exit 0
fi

command -v docker >/dev/null 2>&1 || { log_error "docker is not installed"; exit 1; }

# ── Cover domain pool ─────────────────────────────────────────────────────────
# When VLESS has already been configured, reuse its cover domain pool so both
# protocols share the same rotation list.  Fall back to the built-in pool
# from lib/cover-domains.sh when running standalone.

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  _XRAY_DOMAINS=$(grep -E '^XRAY_COVER_DOMAINS=' "${SCRIPT_DIR}/.env" | head -1 \
    | cut -d= -f2- | tr -d '"' || true)
  if [[ -n "$_XRAY_DOMAINS" ]]; then
    IFS=',' read -ra COVER_DOMAINS <<< "$_XRAY_DOMAINS"
  fi
fi

# ── MTProxy credentials ───────────────────────────────────────────────────────

log_info "Generating MTProxy secret..."

MTG_PORT=2083
MTG_COVER_DOMAIN="${COVER_DOMAINS[$RANDOM % ${#COVER_DOMAINS[@]}]}"
MTG_COVER_DOMAINS=$(IFS=,; echo "${COVER_DOMAINS[*]}")
MTG_ROTATE_MINS=120

MTG_SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret "$MTG_COVER_DOMAIN")
[[ "$MTG_SECRET" =~ ^ee[0-9a-f]{32,}$ ]] || [[ "$MTG_SECRET" =~ ^[A-Za-z0-9_-]{32,}=*$ ]] || {
  log_error "MTProxy secret has unexpected format: '${MTG_SECRET:0:40}'"
  exit 1
}

MTG_LINK="https://t.me/proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${MTG_SECRET}"

# ── Write config file ─────────────────────────────────────────────────────────

mkdir -p "${SCRIPT_DIR}/mtg"
chmod 700 "${SCRIPT_DIR}/mtg"
cat > "${SCRIPT_DIR}/mtg/config.toml" <<EOF
secret = "${MTG_SECRET}"
bind-to = "0.0.0.0:3128"
EOF
chmod 600 "${SCRIPT_DIR}/mtg/config.toml"

# ── Write to .env ─────────────────────────────────────────────────────────────

env_write SERVER_IP         "$SERVER_IP"
env_write MTG_SECRET        "$MTG_SECRET"
env_write MTG_PORT          "$MTG_PORT"
env_write MTG_COVER_DOMAIN  "$MTG_COVER_DOMAIN"
env_write MTG_COVER_DOMAINS "$MTG_COVER_DOMAINS"
env_write MTG_LINK          "$MTG_LINK"
env_write MTG_ROTATE_MINS   "$MTG_ROTATE_MINS"

log_ok "MTProxy configured (cover domain: ${MTG_COVER_DOMAIN})"
