#!/usr/bin/env bash
# setup-telemt.sh — generate telemt (Rust MTProxy v3) credentials and write telemt/config.toml.
#
# telemt is a drop-in Rust replacement for mtg that fixes active-probe detection,
# adds middle-proxy support, and supports multiple simultaneous cover domains.
# See telemt-migration.md for a full comparison and migration guide.
#
# Writes:
#   telemt/config.toml   — telemt server config (raw key + all cover domains)
#   .env                 — MTG_* variables (same keys as mtg for compatibility)
#
# Usage:
#   ./setup-telemt.sh <SERVER_IP>            # fresh setup
#   ./setup-telemt.sh --migrate-from-mtg     # reuse existing MTG_SECRET key + domain
#   ./setup-telemt.sh --force                # regenerate even if already configured
#   ./setup-telemt.sh --server-ip=1.2.3.4
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/env.sh
source "${SCRIPT_DIR}/lib/env.sh"
# shellcheck source=lib/cover-domains.sh
source "${SCRIPT_DIR}/lib/cover-domains.sh"

FORCE=false
MIGRATE=false
SERVER_IP=""

for arg in "$@"; do
  case "$arg" in
    --force)             FORCE=true ;;
    --migrate-from-mtg)  MIGRATE=true ;;
    --server-ip=*)       SERVER_IP="${arg#--server-ip=}" ;;
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
  echo "Usage: $0 <SERVER_IP> [--migrate-from-mtg] [--force]" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || { log_error "python3 is required"; exit 1; }
command -v openssl >/dev/null 2>&1 || { log_error "openssl is required"; exit 1; }

# Skip only when both generated config and required .env state already exist.
# This lets the script repair partially missing state on existing deployments.
if [[ "$FORCE" == false ]] \
    && [[ -f "${SCRIPT_DIR}/telemt/config.toml" ]] \
    && [[ -f "${SCRIPT_DIR}/.env" ]] \
    && grep -qE '^MTG_SECRET=' "${SCRIPT_DIR}/.env" \
    && grep -qE '^MTG_PORT=' "${SCRIPT_DIR}/.env"; then
  _current_profiles=$(grep '^COMPOSE_PROFILES=' "${SCRIPT_DIR}/.env" 2>/dev/null \
    | cut -d= -f2- | tr -d '"' || true)
  if [[ ",${_current_profiles}," == *",telemt,"* ]]; then
    log_info "telemt already configured. Use --force to regenerate."
    exit 0
  fi
fi

MTG_PORT=2083
MTG_ROTATE_MINS=120

# ── Source credentials ────────────────────────────────────────────────────────

if [[ "$MIGRATE" == true ]]; then
  [[ -f "${SCRIPT_DIR}/.env" ]] || { log_error ".env not found — run generate-secrets.sh first"; exit 1; }

  EXISTING_SECRET=$(grep -E '^MTG_SECRET=' "${SCRIPT_DIR}/.env" | head -1 | cut -d= -f2- | tr -d '"' || true)
  [[ -n "$EXISTING_SECRET" ]] || { log_error "MTG_SECRET not found in .env"; exit 1; }
  [[ "$EXISTING_SECRET" =~ ^ee[0-9a-f]{32} ]] || {
    log_error "MTG_SECRET does not look like an FakeTLS (ee...) secret: ${EXISTING_SECRET:0:10}..."
    exit 1
  }

  # Extract 32-hex raw key (bytes 3–34 of the ee... string)
  RAW_KEY="${EXISTING_SECRET:2:32}"
  # Recover cover domain from the trailing hex
  DOMAIN_HEX="${EXISTING_SECRET:34}"
  COVER_DOMAIN=$(python3 -c \
    "import binascii,sys; print(binascii.unhexlify(sys.argv[1]).decode())" \
    "$DOMAIN_HEX")
  log_info "Migrating from mtg: key preserved, cover domain: ${COVER_DOMAIN}"
else
  RAW_KEY=$(openssl rand -hex 16)
  # Use shared cover-domain pool from lib/cover-domains.sh; prefer the Xray
  # pool when already configured so both protocols share the same rotation list.
  if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    _XRAY_DOMAINS=$(grep -E '^XRAY_COVER_DOMAINS=' "${SCRIPT_DIR}/.env" | head -1 \
      | cut -d= -f2- | tr -d '"' || true)
    if [[ -n "$_XRAY_DOMAINS" ]]; then
      IFS=',' read -ra COVER_DOMAINS <<< "$_XRAY_DOMAINS"
    fi
  fi
  COVER_DOMAIN="${COVER_DOMAINS[$RANDOM % ${#COVER_DOMAINS[@]}]}"
fi

COVER_DOMAINS_STR=$(IFS=,; echo "${COVER_DOMAINS[*]}")

# Build the full FakeTLS secret (same ee<key><domain-hex> format as mtg)
DOMAIN_HEX=$(python3 -c \
  "import binascii,sys; print(binascii.hexlify(sys.argv[1].encode()).decode())" \
  "$COVER_DOMAIN")
MTG_SECRET="ee${RAW_KEY}${DOMAIN_HEX}"
MTG_LINK="https://t.me/proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${MTG_SECRET}"

# ── Build tls_domains TOML array (all 35 cover domains for simultaneous links) ─

TOML_DOMAIN_LINES=""
last_idx=$(( ${#COVER_DOMAINS[@]} - 1 ))
for i in "${!COVER_DOMAINS[@]}"; do
  if (( i < last_idx )); then
    TOML_DOMAIN_LINES+="  \"${COVER_DOMAINS[$i]}\","$'\n'
  else
    TOML_DOMAIN_LINES+="  \"${COVER_DOMAINS[$i]}\""$'\n'
  fi
done

# ── Write telemt/config.toml ──────────────────────────────────────────────────

mkdir -p "${SCRIPT_DIR}/telemt"
chmod 700 "${SCRIPT_DIR}/telemt"
cat > "${SCRIPT_DIR}/telemt/config.toml" <<EOF
# telemt/config.toml — generated by setup-telemt.sh
# See telemt-migration.md for full configuration reference.

[general]
use_middle_proxy = true   # route through Telegram middle-proxy; bypasses DC-IP blocking
log_level = "normal"

[general.modes]
classic = false
secure  = false
tls     = true            # FakeTLS (ee) mode only

[general.links]
show = "*"                # print all user links on startup

[server]
port = 443                # telemt always listens on 443 inside the container;
                          # host mapping (2083:443) is in docker-compose.yml

[server.api]
enabled   = true
listen    = "0.0.0.0:9091"
whitelist = ["127.0.0.0/8"]

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain   = "${COVER_DOMAIN}"
tls_domains  = [
${TOML_DOMAIN_LINES}]
unknown_sni_action = "mask"
mask               = true
tls_emulation      = true    # calibrate ServerHello noise to the real cert-chain size
tls_front_dir      = "/run/tlsfront"   # writable tmpfs (see docker-compose.yml)

[access.users]
default = "${RAW_KEY}"

[access]
replay_check_len   = 65536
replay_window_secs = 120
EOF
chmod 600 "${SCRIPT_DIR}/telemt/config.toml"

# ── Write to .env ─────────────────────────────────────────────────────────────
# Reuse MTG_* keys so render-credentials-page.sh and check.sh need no changes
# when switching between mtg and telemt backends.

env_write SERVER_IP         "$SERVER_IP"
env_write MTG_SECRET        "$MTG_SECRET"
env_write MTG_PORT          "$MTG_PORT"
env_write MTG_COVER_DOMAIN  "$COVER_DOMAIN"
env_write MTG_COVER_DOMAINS "$COVER_DOMAINS_STR"
env_write MTG_LINK          "$MTG_LINK"
env_write MTG_ROTATE_MINS   "$MTG_ROTATE_MINS"

log_ok "telemt configured (cover domain: ${COVER_DOMAIN})"

# ── Ensure COMPOSE_PROFILES includes 'telemt' ─────────────────────────────────
# When run standalone (not via generate-secrets.sh), COMPOSE_PROFILES may be
# absent or still set to mtproxy-mtg.  Update it so 'docker compose up -d'
# starts telemt without requiring an explicit --profile flag.
_current_profiles=$(grep '^COMPOSE_PROFILES=' "${SCRIPT_DIR}/.env" 2>/dev/null \
  | cut -d= -f2- | tr -d '"' || true)
_new_profiles=$(printf '%s' "${_current_profiles:-}" \
  | tr ',' '\n' | grep -v -E '^(mtproxy-mtg|telemt)$' | tr '\n' ',' | sed 's/,$//' || true)
[[ -n "$_new_profiles" ]] \
  && _new_profiles="${_new_profiles},telemt" \
  || _new_profiles="telemt"
env_write COMPOSE_PROFILES "$_new_profiles"

log_info "Enable with: COMPOSE_PROFILES=...,telemt  (not mtproxy-mtg)"
log_info "Start with:  docker compose up -d telemt"
log_info "User links:  curl -s http://127.0.0.1:9091/v1/users | python3 -m json.tool"
