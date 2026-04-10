#!/usr/bin/env bash
# clean-install.sh — wipe all generated secrets and configs for a fresh install.
#
# By default (no flags), removes generated project files and Docker containers
# and volumes. Does not touch host-level resources installed by setup-nginx.sh.
#
# Usage:
#   ./clean-install.sh              # clean project files + Docker (confirm first)
#   ./clean-install.sh --host       # also remove host-level resources (requires root)
#   ./clean-install.sh --certs      # also remove Let's Encrypt SSL certs (implies --host)
#   ./clean-install.sh --yes        # skip confirmation prompt
#   ./clean-install.sh --dry-run    # preview what would be removed, do nothing
#   sudo ./clean-install.sh --host --yes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

DRY_RUN=false
AUTO_YES=false
CLEAN_HOST=false
CLEAN_CERTS=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=true ;;
    --yes|-y)    AUTO_YES=true ;;
    --host)      CLEAN_HOST=true ;;
    --certs)     CLEAN_CERTS=true; CLEAN_HOST=true ;;
    -*)
      log_error "Unknown option: $arg"
      echo "Usage: $0 [--host] [--certs] [--yes] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

if $CLEAN_HOST && [[ $EUID -ne 0 ]]; then
  log_error "--host requires root. Run: sudo $0 --host"
  exit 1
fi

# Load WEBROOT from .env if present; fall back to setup-nginx.sh default
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a; source "${SCRIPT_DIR}/.env"; set +a
fi
WEBROOT="${CREDENTIALS_WEBROOT:-/var/www/vpn}"

# ── Build what-will-be-removed list for the confirmation prompt ───────────────

WILL_REMOVE=()
[[ -f "${SCRIPT_DIR}/.env" ]]              && WILL_REMOVE+=("  .env")
[[ -d "${SCRIPT_DIR}/mtg" ]]               && WILL_REMOVE+=("  mtg/")
[[ -d "${SCRIPT_DIR}/telemt" ]]            && WILL_REMOVE+=("  telemt/")
[[ -d "${SCRIPT_DIR}/xray" ]]              && WILL_REMOVE+=("  xray/")
[[ -d "${SCRIPT_DIR}/wireguard" ]]         && WILL_REMOVE+=("  wireguard/")
[[ -d "${SCRIPT_DIR}/ipsec" ]]             && WILL_REMOVE+=("  ipsec/")
[[ -f "${SCRIPT_DIR}/web/index.html" ]]    && WILL_REMOVE+=("  web/index.html")
[[ -f "${SCRIPT_DIR}/web/.htpasswd" ]]     && WILL_REMOVE+=("  web/.htpasswd")
[[ -f "${SCRIPT_DIR}/.last_mtg_rotation" ]] && WILL_REMOVE+=("  .last_mtg_rotation")
[[ -f "${SCRIPT_DIR}/.last_xray_rotation" ]] && WILL_REMOVE+=("  .last_xray_rotation")
[[ -f "${SCRIPT_DIR}/.check_env" ]]        && WILL_REMOVE+=("  .check_env")
WILL_REMOVE+=("  Docker containers + named volumes (prometheus-data, grafana-data)")

if $CLEAN_HOST; then
  [[ -f /etc/systemd/system/hogen-vpn.service ]] \
    && WILL_REMOVE+=("  /etc/systemd/system/hogen-vpn.service (+ rotation/check timers)")
  [[ -f /etc/nginx/sites-available/vpn ]] \
    && WILL_REMOVE+=("  /etc/nginx/sites-available/vpn + conf.d fragments")
  [[ -d "$WEBROOT" ]] \
    && WILL_REMOVE+=("  ${WEBROOT}/ (credentials webroot)")
  [[ -f /etc/fail2ban/jail.d/hogen-vpn.conf ]] \
    && WILL_REMOVE+=("  fail2ban rules (hogen-vpn)")
  [[ -f /etc/sysctl.d/99-hogen-vpn.conf ]] \
    && WILL_REMOVE+=("  /etc/sysctl.d/99-hogen-vpn.conf")
fi
if $CLEAN_CERTS; then
  [[ -d /etc/letsencrypt ]] \
    && WILL_REMOVE+=("  /etc/letsencrypt/ (ALL Let's Encrypt certificates)")
fi

# ── Confirm ───────────────────────────────────────────────────────────────────

if ! $AUTO_YES && ! $DRY_RUN; then
  echo ""
  log_warn "This will PERMANENTLY remove all generated credentials and configs:"
  for item in "${WILL_REMOVE[@]}"; do echo "$item"; done
  echo ""
  if $CLEAN_CERTS; then
    log_warn "WARNING: --certs will delete ALL Let's Encrypt certificates on this server."
    echo ""
  fi
  printf 'Type "yes" to continue: '
  read -r CONFIRM
  [[ "$CONFIRM" == "yes" ]] || { log_info "Aborted."; exit 0; }
  echo ""
elif $DRY_RUN; then
  log_info "Dry-run mode — nothing will be modified."
  echo ""
  for item in "${WILL_REMOVE[@]}"; do echo "  would remove: ${item## }"; done
  echo ""
  log_ok "Dry run complete."
  exit 0
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

_rm() {
  for target in "$@"; do
    if [[ -e "$target" || -L "$target" ]]; then
      rm -rf "$target"
      log_info "Removed: $target"
    fi
  done
}

_systemd_unit_remove() {
  local unit="$1"
  if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^${unit}"; then
    systemctl disable --now "$unit" 2>/dev/null || true
    log_info "Disabled: $unit"
  fi
  _rm "/etc/systemd/system/${unit}"
}

# ── Stop Docker Compose ───────────────────────────────────────────────────────

log_info "Stopping Docker Compose services and removing volumes..."
if command -v docker >/dev/null 2>&1; then
  docker compose -f "${SCRIPT_DIR}/docker-compose.yml" \
    down --volumes --remove-orphans 2>/dev/null || true
  log_ok "Docker services stopped; named volumes removed."
else
  log_warn "docker not found — skipping container teardown."
fi

# ── Remove generated project files ───────────────────────────────────────────

log_info "Removing generated project files..."
_rm \
  "${SCRIPT_DIR}/.env" \
  "${SCRIPT_DIR}/mtg" \
  "${SCRIPT_DIR}/telemt" \
  "${SCRIPT_DIR}/xray" \
  "${SCRIPT_DIR}/wireguard" \
  "${SCRIPT_DIR}/ipsec" \
  "${SCRIPT_DIR}/web/index.html" \
  "${SCRIPT_DIR}/web/.htpasswd" \
  "${SCRIPT_DIR}/.last_mtg_rotation" \
  "${SCRIPT_DIR}/.last_xray_rotation" \
  "${SCRIPT_DIR}/.check_env"

# Remove Python cache left by setup scripts (openssl / binascii calls)
_rm "${SCRIPT_DIR}/__pycache__"

# ── Remove host-level resources (--host, root only) ───────────────────────────

if $CLEAN_HOST; then
  log_info "Removing systemd units..."
  for unit in \
    hogen-vpn.service \
    vpn-reality-cover-rotate.timer \
    vpn-reality-cover-rotate.service \
    vpn-mtg-rotate.timer \
    vpn-mtg-rotate.service \
    vpn-health-check.timer \
    vpn-health-check.service; do
    _systemd_unit_remove "$unit"
  done
  systemctl daemon-reload
  log_info "systemd daemon reloaded."

  log_info "Removing nginx config..."
  _rm \
    /etc/nginx/sites-enabled/vpn \
    /etc/nginx/sites-available/vpn \
    /etc/nginx/conf.d/vpn-ratelimit.conf \
    /etc/nginx/conf.d/vpn-ws-upgrade.conf \
    /etc/nginx/conf.d/vpn-check-local.conf \
    /etc/nginx/.htpasswd-proxy
  if nginx -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null || true
    log_info "nginx reloaded."
  else
    log_warn "nginx config has errors after removal — skipping reload."
  fi

  log_info "Removing fail2ban rules..."
  _rm \
    /etc/fail2ban/jail.d/hogen-vpn.conf \
    /etc/fail2ban/filter.d/nginx-path-probe.conf
  fail2ban-client reload 2>/dev/null || true

  log_info "Removing sysctl config..."
  _rm /etc/sysctl.d/99-hogen-vpn.conf
  # Disable ip_forward since we set it; a reboot would also clear it
  sysctl -w net.ipv4.ip_forward=0 2>/dev/null || true

  log_info "Removing credentials webroot (${WEBROOT})..."
  _rm "$WEBROOT"
fi

# ── Remove SSL certificates (--certs, very destructive) ───────────────────────

if $CLEAN_CERTS; then
  log_warn "Removing Let's Encrypt certificates..."
  if command -v certbot >/dev/null 2>&1 && [[ -n "${CREDENTIALS_DOMAIN:-}" ]]; then
    certbot delete --cert-name "$CREDENTIALS_DOMAIN" --non-interactive 2>/dev/null || true
  fi
  _rm /etc/letsencrypt
fi

# ── Done ──────────────────────────────────────────────────────────────────────

log_ok ""
log_ok "Clean complete."
log_ok "Run generate-secrets.sh to set up fresh credentials."
$CLEAN_HOST && log_info "Run setup-nginx.sh to reinstall the nginx vhost and systemd units." || true
