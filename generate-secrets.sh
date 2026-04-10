#!/usr/bin/env bash
# generate-secrets.sh — generate all VPN credentials in one shot.
#
# This is the master orchestrator. Each protocol's credential generation lives
# in its own script (setup-xray.sh, setup-mtg.sh, setup-ikev2.sh,
# setup-wireguard.sh) and can also be run standalone to regenerate a single
# protocol without touching the others.
#
# Usage:
#   ./generate-secrets.sh <SERVER_IP> [options]
#
# Options:
#   --services=LIST   Comma-separated list of optional profiles to enable.
#                     MTProxy backend (mutually exclusive, choose one):
#                       mtproxy-mtg  classic nineseconds/mtg v2 (default)
#                       telemt        Rust MTProxy v3 replacement
#                     Optional services: xray, ikev2, wireguard, monitoring
#                     Example: --services=xray,wireguard,mtproxy-mtg
#                     Example: --services=xray,telemt  (telemt instead of mtg)
#   --cover-domain=DOMAIN   Pin the VLESS+Reality SNI cover domain.
#   --credentials-domain=DOMAIN  Set the credentials-page FQDN.
#   --force           Remove existing .env and regenerate all secrets.
#                     WARNING: breaks all connected VPN clients.
#   --dry-run         Preview what would happen without writing any files or
#                     pulling Docker images. Safe to run anywhere.
#
# Positional form (legacy, still supported):
#   ./generate-secrets.sh <SERVER_IP> [REALITY_COVER_DOMAIN] [CREDENTIALS_DOMAIN]
#
# To regenerate a single protocol after initial setup:
#   ./setup-wireguard.sh --force
#   ./setup-xray.sh --force
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

SERVER_IP=""
REALITY_COVER_DOMAIN=""
CREDENTIALS_DOMAIN=""
FORCE=false
DRY_RUN=false
# Possible services: xray, ikev2, wireguard, monitoring, mtproxy-mtg, telemt
# (mtproxy-mtg and telemt are mutually exclusive — they share host port 2083).
# Default includes mtproxy-mtg so the classic mtg backend starts automatically.
SERVICES=""

for arg in "$@"; do
  case "$arg" in
    --services=*)           SERVICES="${arg#--services=}" ;;
    --cover-domain=*)       REALITY_COVER_DOMAIN="${arg#--cover-domain=}" ;;
    --credentials-domain=*) CREDENTIALS_DOMAIN="${arg#--credentials-domain=}" ;;
    --force)                FORCE=true ;;
    --dry-run)              DRY_RUN=true ;;
    -*)
      echo "Usage: $0 <SERVER_IP> [--services=LIST] [--cover-domain=DOMAIN] [--credentials-domain=DOMAIN] [--force] [--dry-run]" >&2
      exit 1
      ;;
    *)
      if   [[ -z "$SERVER_IP" ]];            then SERVER_IP="$arg"
      elif [[ -z "$REALITY_COVER_DOMAIN" ]]; then REALITY_COVER_DOMAIN="$arg"
      elif [[ -z "$CREDENTIALS_DOMAIN" ]];   then CREDENTIALS_DOMAIN="$arg"
      fi
      ;;
  esac
done

if [[ -z "$SERVER_IP" ]]; then
  echo "Usage: $0 <SERVER_IP> [--services=LIST] [--cover-domain=DOMAIN] [--credentials-domain=DOMAIN] [--force] [--dry-run]"
  echo ""
  echo "  --services=LIST   Comma-separated profiles to enable."
  echo "                    MTProxy (choose one): mtproxy-mtg (default), telemt"
  echo "                    Optional services:   xray, ikev2, wireguard, monitoring"
  echo "                    Example: --services=xray,wireguard,mtproxy-mtg"
  echo "                    Example: --services=xray,telemt   (use telemt instead of mtg)"
  echo "  --force           Remove existing .env and regenerate all secrets."
  echo "                    WARNING: breaks all connected VPN clients."
  echo "  --dry-run         Preview what would happen without writing any files or"
  echo "                    pulling images. Safe to run on any machine."
  echo "Example: $0 1.2.3.4"
  echo "Example: $0 1.2.3.4 --services=xray,wireguard"
  echo "Example: $0 1.2.3.4 github.com vpn.example.com"
  exit 1
fi

# Helper: test whether a service is in the SERVICES list
_svc() { [[ ",$SERVICES," == *",$1,"* ]]; }

# ── Resolve MTProxy backend early — fail fast before any I/O ─────────────────
# mtproxy-mtg and telemt are mutually exclusive: they bind the same host port.
# When neither is specified, default to mtproxy-mtg (classic mtg backend).
if _svc telemt && _svc mtproxy-mtg; then
  log_error "Cannot enable both 'mtproxy-mtg' and 'telemt' in --services"
  exit 1
elif _svc telemt; then
  _MTPROXY_BACKEND="telemt"
else
  # Default to mtg; add its profile so Docker Compose starts it.
  _MTPROXY_BACKEND="mtg"
  [[ ",$SERVICES," != *",mtproxy-mtg,"* ]] \
    && SERVICES="${SERVICES:+${SERVICES},}mtproxy-mtg"
fi

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  if [[ "$FORCE" == true ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      log_warn "[dry-run] Would remove existing .env and regenerate all secrets."
      log_warn "[dry-run] All connected VPN clients would need to re-import credentials."
    else
      log_warn "--force: removing existing .env — all secrets will be regenerated."
      log_warn "All connected VPN clients will need to re-import credentials."
      rm -f "${SCRIPT_DIR}/.env"
    fi
  elif [[ "$DRY_RUN" == false ]]; then
    log_error ".env already exists. Delete it first to regenerate all secrets."
    log_info  "To regenerate a single protocol, run its setup script with --force:"
    log_info  "  ./setup-xray.sh --force | ./setup-mtg.sh --force | ./setup-telemt.sh --force | ./setup-ikev2.sh --force | ./setup-wireguard.sh --force"
    log_info  "To regenerate ALL secrets (breaks all existing clients): $0 --force $SERVER_IP ${SERVICES:+--services=${SERVICES}}"
    exit 1
  fi
fi

if [[ "$DRY_RUN" == false ]]; then
  command -v docker  >/dev/null 2>&1 || { log_error "docker is not installed";  exit 1; }
  command -v openssl >/dev/null 2>&1 || { log_error "openssl is not installed"; exit 1; }
fi

# ── Pull all runtime images upfront ──────────────────────────────────────────
# Pull only the images for enabled services so 'docker compose up' works
# immediately after without an extra pull step.

# _run_setup: call a setup sub-script, or in --dry-run mode just log it.
_run_setup() {
  local script="$1"; shift
  if [[ "$DRY_RUN" == true ]]; then
    log_info "[dry-run] Would run: $(basename "$script")${*:+ $*}"
  else
    "$script" "$@"
  fi
}

if [[ "$DRY_RUN" == true ]]; then
  log_info "[dry-run] Would pull Docker images for: ${_MTPROXY_BACKEND}${SERVICES:+, ${SERVICES}}"
else
  log_info "Pulling Docker images..."
  if [[ "$_MTPROXY_BACKEND" == "telemt" ]]; then
    docker pull --quiet ghcr.io/telemt/telemt:latest >/dev/null
  else
    docker pull --quiet nineseconds/mtg:2 >/dev/null
  fi
  _svc xray      && docker pull --quiet ghcr.io/xtls/xray-core:26.3.27 >/dev/null
  _svc ikev2     && docker pull --quiet hwdsl2/ipsec-vpn-server:latest >/dev/null
  if _svc wireguard; then
    docker pull --quiet lscr.io/linuxserver/wireguard:latest >/dev/null
    docker pull --quiet donaldzou/wgdashboard:latest >/dev/null
    docker pull --quiet alpine:3 >/dev/null   # used for WireGuard key generation
  fi
  if _svc monitoring; then
    docker pull --quiet gcr.io/cadvisor/cadvisor:latest >/dev/null
    docker pull --quiet prom/prometheus:latest >/dev/null
    docker pull --quiet grafana/grafana:latest >/dev/null
  fi
fi

# ── Seed .env with common vars before calling sub-scripts ────────────────────

if [[ "$DRY_RUN" == true ]]; then
  log_info "[dry-run] Would write .env:"
  log_info "           SERVER_IP=${SERVER_IP}"
  log_info "           CREDENTIALS_DOMAIN=${CREDENTIALS_DOMAIN:-<empty>}"
  log_info "           CREDENTIALS_WEBROOT=/var/www/vpn"
  log_info "           COMPOSE_PROFILES=${SERVICES}"
else
  printf 'SERVER_IP=%s\n'            "$SERVER_IP"         > "${SCRIPT_DIR}/.env"
  printf 'CREDENTIALS_DOMAIN=%s\n'   "$CREDENTIALS_DOMAIN" >> "${SCRIPT_DIR}/.env"
  printf 'CREDENTIALS_WEBROOT=%s\n'  "/var/www/vpn"        >> "${SCRIPT_DIR}/.env"
  # COMPOSE_PROFILES is read by Docker Compose from .env automatically;
  # it controls which optional-service profiles are started on 'docker compose up'.
  printf 'COMPOSE_PROFILES=%s\n'     "$SERVICES"           >> "${SCRIPT_DIR}/.env"
  chmod 600 "${SCRIPT_DIR}/.env"
fi

# ── Per-protocol credential generation ───────────────────────────────────────
# Exactly one MTProxy backend is generated; all others are optional.
# When --force was used, propagate it so sub-scripts overwrite existing state.
# Use ${arr[@]+"${arr[@]}"} instead of "${arr[@]}" to avoid bash < 4.4 nounset
# trap: empty arrays are treated as unset by older bash, causing "unbound variable".
_SETUP_FLAGS=()
[[ "$FORCE"    == true ]] && _SETUP_FLAGS+=(--force)
[[ "$DRY_RUN" == true ]] && _SETUP_FLAGS+=(--dry-run)

if _svc xray; then
  _run_setup "${SCRIPT_DIR}/setup-xray.sh" ${_SETUP_FLAGS[@]+"${_SETUP_FLAGS[@]}"} \
    ${REALITY_COVER_DOMAIN:+"--cover-domain=${REALITY_COVER_DOMAIN}"}
else
  log_warn "Xray (VLESS+Reality / Shadowsocks) skipped — not in --services list."
fi

if [[ "$_MTPROXY_BACKEND" == "telemt" ]]; then
  _run_setup "${SCRIPT_DIR}/setup-telemt.sh" ${_SETUP_FLAGS[@]+"${_SETUP_FLAGS[@]}"}
else
  _run_setup "${SCRIPT_DIR}/setup-mtg.sh" ${_SETUP_FLAGS[@]+"${_SETUP_FLAGS[@]}"}
fi

if _svc ikev2; then
  _run_setup "${SCRIPT_DIR}/setup-ikev2.sh" ${_SETUP_FLAGS[@]+"${_SETUP_FLAGS[@]}"}
else
  log_warn "IKEv2/IPSec skipped — not in --services list."
fi

if _svc wireguard; then
  _run_setup "${SCRIPT_DIR}/setup-wireguard.sh" ${_SETUP_FLAGS[@]+"${_SETUP_FLAGS[@]}"}
else
  log_warn "WireGuard skipped — not in --services list."
fi

# ── Page token (written last; only needed by setup-nginx.sh) ─────────────────

if [[ "$DRY_RUN" == true ]]; then
  log_info "[dry-run] Would write PAGE_TOKEN=<random 16-byte hex> to .env"
else
  PAGE_TOKEN=$(openssl rand -hex 16)
  printf 'PAGE_TOKEN=%s\n' "$PAGE_TOKEN" >> "${SCRIPT_DIR}/.env"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == true ]]; then
  log_ok ""
  log_ok "Dry-run complete — no files written. With these arguments:"
  log_ok "  SERVER_IP=${SERVER_IP}  SERVICES=${SERVICES}  FORCE=${FORCE}"
  log_ok ""
  log_ok "The following files would be written:"
  log_ok "  .env                    — all credentials (COMPOSE_PROFILES=${SERVICES})"
  if [[ "$_MTPROXY_BACKEND" == "telemt" ]]; then
    log_ok "  telemt/config.toml      — telemt MTProxy config"
  else
    log_ok "  mtg/config.toml         — MTProxy config"
  fi
  _svc xray      && log_ok "  xray/config.json        — VLESS + Shadowsocks config"
  _svc wireguard && log_ok "  wireguard/wg0.conf      — WireGuard server config"
  _svc wireguard && log_ok "  wireguard/peer1.conf    — WireGuard client config"
  log_ok ""
  log_ok "MTProxy backend:  ${_MTPROXY_BACKEND}"
  _svc xray      && log_ok "REALITY cover domain: ${REALITY_COVER_DOMAIN:-<randomly chosen from pool>}"
  log_ok ""
  log_info "Remove --dry-run to apply."
  exit 0
fi

set -a; source "${SCRIPT_DIR}/.env"; set +a

log_ok ""
log_ok "Done. Files written:"
log_ok "  .env                    — all credentials (COMPOSE_PROFILES=${SERVICES})"
if [[ "$_MTPROXY_BACKEND" == "telemt" ]]; then
  log_ok "  telemt/config.toml      — telemt MTProxy config"
else
  log_ok "  mtg/config.toml         — MTProxy config"
fi
_svc xray      && log_ok "  xray/config.json        — VLESS + Shadowsocks config"
_svc wireguard && log_ok "  wireguard/wg0.conf      — WireGuard server config"
_svc wireguard && log_ok "  wireguard/peer1.conf    — WireGuard client config"
log_ok ""
log_ok "MTProxy backend:       ${_MTPROXY_BACKEND}"
log_ok "MTProxy cover domain:  ${MTG_COVER_DOMAIN}"
_svc xray      && log_ok "REALITY cover domain:  ${XRAY_SNI}"
_svc xray      && log_ok "Shadowsocks method:    ${SS_METHOD}"
_svc ikev2     && log_ok "IKEv2 user:            ${IKE_USER}"
_svc wireguard && log_ok "WireGuard client IP:   ${WG_CLIENT_IP}"
log_ok ""
log_ok "Credentials page token:  ${PAGE_TOKEN}"
log_ok "(Share URL: https://<CREDENTIALS_DOMAIN>/${PAGE_TOKEN}/)"
log_ok ""
log_info "Next: sudo ./setup-nginx.sh && docker compose up -d"
_svc ikev2 && log_info "IKEv2 post-start: once containers are healthy, run ./setup-ipsec.sh"
