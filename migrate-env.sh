#!/usr/bin/env bash
# migrate-env.sh — backfill variables that are absent from an existing .env.
#
# Safe to run repeatedly (idempotent). Never overwrites existing values.
# Useful after upgrading the repo when new variables have been added.
#
# Usage:
#   sudo ./migrate-env.sh            # uses .env in the same directory
#   sudo ./migrate-env.sh /path/.env  # explicit path
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

ENV_FILE="${1:-${SCRIPT_DIR}/.env}"

[[ -f "$ENV_FILE" ]] || {
  log_error ".env not found at '${ENV_FILE}' — run generate-secrets.sh first"
  exit 1
}

# Load current values (suppress unbound-variable errors for old files)
set +u
set -a; source "$ENV_FILE"; set +a
set -u

ADDED=()
SKIPPED=()

# ── helpers ──────────────────────────────────────────────────────────────────

# has_key KEY — true if KEY= appears in the file (even if value is empty)
has_key() { grep -qE "^${1}=" "$ENV_FILE"; }

# ensure_newline — guarantee the file ends with a newline before we append
ensure_newline() {
  [[ -s "$ENV_FILE" ]] && [[ "$(tail -c1 "$ENV_FILE" | wc -c)" -gt 0 ]] && \
    [[ "$(tail -c1 "$ENV_FILE")" != $'\n' ]] && printf '\n' >> "$ENV_FILE" || true
}

# add KEY LINE [COMMENT]
#   Appends "# COMMENT\nLINE\n" to the file if KEY is absent.
#   LINE should be the full assignment, e.g. XRAY_ROTATE_MINS=120
add() {
  local key="$1" line="$2" comment="${3:-}"
  if has_key "$key"; then
    SKIPPED+=("$key")
    return
  fi
  ensure_newline
  if [[ -n "$comment" ]]; then
    printf '\n# %s\n' "$comment" >> "$ENV_FILE"
  else
    printf '\n' >> "$ENV_FILE"
  fi
  printf '%s\n' "$line" >> "$ENV_FILE"
  ADDED+=("$key")
}

# ── migrations ───────────────────────────────────────────────────────────────

# COMPOSE_PROFILES — controls which optional Docker Compose profiles are active.
# Existing deployments had all services plus one MTProxy backend. Prefer telemt
# when its generated config exists; otherwise fall back to classic mtg.
DEFAULT_MTPROXY_PROFILE="mtproxy-mtg"
[[ -f "${SCRIPT_DIR}/telemt/config.toml" ]] && DEFAULT_MTPROXY_PROFILE="telemt"
add "COMPOSE_PROFILES" "COMPOSE_PROFILES=xray,ikev2,wireguard,monitoring,${DEFAULT_MTPROXY_PROFILE}" \
  "Docker Compose profiles to enable (xray, ikev2, wireguard, monitoring, choose one MTProxy backend: mtproxy-mtg or telemt)"

# XRAY_ROTATE_MINS (renamed from XRAY_ROTATE_HOURS)
if ! has_key "XRAY_ROTATE_MINS"; then
  if has_key "XRAY_ROTATE_HOURS"; then
    OLD_H=$(grep -E '^XRAY_ROTATE_HOURS=' "$ENV_FILE" | head -1 | cut -d= -f2)
    if [[ "$OLD_H" =~ ^[0-9]+$ ]]; then
      NEW_M=$(( OLD_H * 60 ))
    else
      NEW_M=120
    fi
    add "XRAY_ROTATE_MINS" "XRAY_ROTATE_MINS=${NEW_M}" \
      "migrated from XRAY_ROTATE_HOURS=${OLD_H} (${OLD_H}h → ${NEW_M}min)"
  else
    add "XRAY_ROTATE_MINS" "XRAY_ROTATE_MINS=120" \
      "rotation interval in minutes (0 = disabled)"
  fi
fi

# MTG_ROTATE_MINS
add "MTG_ROTATE_MINS" "MTG_ROTATE_MINS=120" \
  "MTProxy rotation interval in minutes (0 = disabled)"

# MTG_COVER_DOMAINS — fall back to XRAY_COVER_DOMAINS pool
if ! has_key "MTG_COVER_DOMAINS"; then
  POOL="${XRAY_COVER_DOMAINS:-}"
  add "MTG_COVER_DOMAINS" "MTG_COVER_DOMAINS=${POOL}" \
    "comma-separated FakeTLS cover domain pool for MTProxy rotation"
fi

# MTG_COVER_DOMAIN — fall back to current SNI
if ! has_key "MTG_COVER_DOMAIN"; then
  DOMAIN="${XRAY_SNI:-}"
  add "MTG_COVER_DOMAIN" "MTG_COVER_DOMAIN=${DOMAIN}" \
    "currently active FakeTLS cover domain"
fi

# MTG_LINK — derive from existing credentials
if ! has_key "MTG_LINK"; then
  _IP="${SERVER_IP:-}"
  _PORT="${MTG_PORT:-2083}"
  _SEC="${MTG_SECRET:-}"
  add "MTG_LINK" \
    "MTG_LINK=\"https://t.me/proxy?server=${_IP}&port=${_PORT}&secret=${_SEC}\"" \
    "Telegram proxy deep-link"
fi

# CREDENTIALS_WEBROOT
add "CREDENTIALS_WEBROOT" "CREDENTIALS_WEBROOT=/var/www/vpn" \
  "webroot for the nginx credentials page"

# CREDENTIALS_DOMAIN
add "CREDENTIALS_DOMAIN" "CREDENTIALS_DOMAIN=${CREDENTIALS_DOMAIN:-}" \
  "domain for the nginx credentials page (required by setup-nginx.sh)"

# NGINX_VHOST_PATH
add "NGINX_VHOST_PATH" "NGINX_VHOST_PATH=" \
  "override nginx vhost path (default: /etc/nginx/sites-available/vpn)"

# VPN_DNS_NAME
add "VPN_DNS_NAME" "VPN_DNS_NAME=" \
  "optional FQDN for IKEv2 server identity (improves Apple client reconnection)"

# LETSENCRYPT_EMAIL
add "LETSENCRYPT_EMAIL" "LETSENCRYPT_EMAIL=" \
  "optional email for Let's Encrypt expiry notifications"

# ── report ───────────────────────────────────────────────────────────────────

if (( ${#ADDED[@]} == 0 )); then
  log_ok ".env is already up to date — no variables were missing."
else
  log_ok "Added ${#ADDED[@]} missing variable(s) to ${ENV_FILE}:"
  for v in "${ADDED[@]}"; do log_info "  + $v"; done
  if has_key "XRAY_ROTATE_HOURS" && has_key "XRAY_ROTATE_MINS"; then
    log_warn "XRAY_ROTATE_HOURS still exists in .env alongside XRAY_ROTATE_MINS — you can safely remove it."
  fi
  log_info "Next steps:"
  log_info "  1. Review ${ENV_FILE}"
  log_info "  2. sudo ./setup-nginx.sh   # re-installs systemd timers with new vars"
fi
