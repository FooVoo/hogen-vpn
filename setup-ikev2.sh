#!/usr/bin/env bash
# setup-ikev2.sh — generate IKEv2/IPSec credentials (PSK, username, password).
#
# No config file is written — the hwdsl2/ipsec-vpn-server Docker image reads
# its credentials directly from environment variables defined in docker-compose.yml,
# which are sourced from .env at compose-up time.
#
# Writes:
#   .env  — IKE_PSK, IKE_USER, IKE_PASSWORD
#
# Usage:
#   ./setup-ikev2.sh <SERVER_IP>
#   ./setup-ikev2.sh                    # reads SERVER_IP from existing .env
#   ./setup-ikev2.sh --force            # regenerate even if already configured
#   ./setup-ikev2.sh --server-ip=1.2.3.4
#
# After running this script (or regenerating credentials with --force), restart
# the ipsec container so Docker Compose re-injects the new env vars:
#   docker compose up -d --force-recreate ipsec
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/env.sh
source "${SCRIPT_DIR}/lib/env.sh"

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
  SERVER_IP=$(grep -E '^SERVER_IP=' "${SCRIPT_DIR}/.env" | head -1 | cut -d= -f2- | tr -d '"')
fi
[[ -n "$SERVER_IP" ]] || {
  log_error "SERVER_IP is required."
  echo "Usage: $0 <SERVER_IP>" >&2
  exit 1
}

# Skip if already configured (unless --force)
if [[ "$FORCE" == false ]] && [[ -f "${SCRIPT_DIR}/.env" ]] \
    && grep -qE '^IKE_PSK=' "${SCRIPT_DIR}/.env"; then
  log_info "IKEv2/IPSec already configured. Use --force to regenerate."
  exit 0
fi

command -v openssl >/dev/null 2>&1 || { log_error "openssl is not installed"; exit 1; }

# ── IKEv2 credentials ─────────────────────────────────────────────────────────

log_info "Generating IKEv2/IPSec credentials..."

IKE_PSK=$(openssl rand -base64 24 | tr -d '\n')
IKE_USER="vpn$(openssl rand -hex 4)"
IKE_PASSWORD=$(openssl rand -hex 8)

# ── Write to .env ─────────────────────────────────────────────────────────────

env_write SERVER_IP    "$SERVER_IP"
env_write IKE_PSK      "$IKE_PSK"
env_write IKE_USER     "$IKE_USER"
env_write IKE_PASSWORD "$IKE_PASSWORD"

log_ok "IKEv2/IPSec configured (user: ${IKE_USER})"
