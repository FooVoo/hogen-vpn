#!/usr/bin/env bash
# setup-wireguard.sh — generate WireGuard credentials and write server/client configs.
#
# Writes:
#   wireguard/wg0.conf      — WireGuard server config (mounted into the container)
#   wireguard/peer1.conf    — WireGuard client config (distributed via credentials page)
#   .env                    — WG_PORT, WG_SERVER_PUBLIC_KEY, WG_CLIENT_PRIVATE_KEY,
#                             WG_CLIENT_PUBLIC_KEY, WG_PSK, WG_CLIENT_IP
#
# Usage:
#   ./setup-wireguard.sh <SERVER_IP>
#   ./setup-wireguard.sh                    # reads SERVER_IP from existing .env
#   ./setup-wireguard.sh --update-config    # rewrite configs from existing keys (no keygen)
#   ./setup-wireguard.sh --force            # regenerate ALL keys + configs (new client config needed)
#   ./setup-wireguard.sh --server-ip=1.2.3.4
#
# Use --update-config to apply PostUp/DNS template changes without invalidating
# existing client configs. Use --force only when keys must change (key compromise).
#
# After either flag, restart the container:
#   docker compose up -d --force-recreate wireguard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/env.sh
source "${SCRIPT_DIR}/lib/env.sh"

FORCE=false
UPDATE_CONFIG=false
SERVER_IP=""

for arg in "$@"; do
  case "$arg" in
    --force)          FORCE=true ;;
    --update-config)  UPDATE_CONFIG=true ;;
    --server-ip=*)    SERVER_IP="${arg#--server-ip=}" ;;
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

WG_PORT=51820
WG_CLIENT_IP="10.13.13.2"

# ── Determine operating mode ──────────────────────────────────────────────────

if [[ "$UPDATE_CONFIG" == true ]]; then
  # --update-config: rewrite wg0.conf + peer1.conf from existing keys.
  # Server private key is intentionally not stored in .env; read from wg0.conf.
  [[ -f "${SCRIPT_DIR}/.env" ]] || {
    log_error "--update-config requires existing keys in .env. Run without flags first."
    exit 1
  }
  _lk() { grep -E "^${1}=" "${SCRIPT_DIR}/.env" | head -1 | cut -d= -f2- | tr -d '"'; }
  WG_SERVER_PUBLIC=$(_lk WG_SERVER_PUBLIC_KEY)
  WG_CLIENT_PRIVATE=$(_lk WG_CLIENT_PRIVATE_KEY)
  WG_CLIENT_PUBLIC=$(_lk WG_CLIENT_PUBLIC_KEY)
  WG_PSK=$(_lk WG_PSK)
  _p=$(_lk WG_PORT);      WG_PORT="${_p:-51820}"
  _c=$(_lk WG_CLIENT_IP); WG_CLIENT_IP="${_c:-10.13.13.2}"
  WG_SERVER_PRIVATE=$(grep -E '^\s*PrivateKey\s*=' "${SCRIPT_DIR}/wireguard/wg0.conf" 2>/dev/null \
    | head -1 | sed 's/^[^=]*=[[:space:]]*//')
  [[ -n "$WG_SERVER_PRIVATE" && -n "$WG_CLIENT_PRIVATE" && -n "$WG_PSK" ]] || {
    log_error "Existing keys not found. Run ./setup-wireguard.sh first."
    exit 1
  }
  log_info "Updating WireGuard configs from existing keys (no key regeneration)..."

elif [[ "$FORCE" == false ]] && [[ -f "${SCRIPT_DIR}/.env" ]] \
    && grep -qE '^WG_SERVER_PUBLIC_KEY=' "${SCRIPT_DIR}/.env"; then
  log_info "WireGuard already configured. Use --update-config to refresh configs or --force to regenerate keys."
  exit 0

else
  # Fresh install or --force: generate new keys.
  command -v docker >/dev/null 2>&1 || { log_error "docker is not installed"; exit 1; }
  log_info "Generating WireGuard credentials..."

  # All keys generated in a single Docker call — alpine + wireguard-tools.
  # Output lines: server_priv, server_pub, client_priv, client_pub, psk
  WG_KEYS=$(docker run --rm alpine:3 sh -c \
    "apk add -q wireguard-tools 2>/dev/null; \
     srv_priv=\$(wg genkey); \
     srv_pub=\$(printf '%s' \"\$srv_priv\" | wg pubkey); \
     cli_priv=\$(wg genkey); \
     cli_pub=\$(printf '%s' \"\$cli_priv\" | wg pubkey); \
     psk=\$(wg genpsk); \
     printf '%s\n%s\n%s\n%s\n%s\n' \"\$srv_priv\" \"\$srv_pub\" \"\$cli_priv\" \"\$cli_pub\" \"\$psk\"")

  WG_SERVER_PRIVATE=$(printf '%s' "$WG_KEYS" | sed -n '1p')
  WG_SERVER_PUBLIC=$(printf '%s'  "$WG_KEYS" | sed -n '2p')
  WG_CLIENT_PRIVATE=$(printf '%s' "$WG_KEYS" | sed -n '3p')
  WG_CLIENT_PUBLIC=$(printf '%s'  "$WG_KEYS" | sed -n '4p')
  WG_PSK=$(printf '%s'            "$WG_KEYS" | sed -n '5p')

  [[ -n "$WG_SERVER_PRIVATE" && -n "$WG_CLIENT_PRIVATE" && -n "$WG_PSK" ]] || {
    log_error "Failed to generate WireGuard credentials"
    exit 1
  }
fi

# ── Write server config ───────────────────────────────────────────────────────
# Docker Compose creates missing bind-mount sources as directories; remove any
# such stale directory before writing the file.
#
# PostUp/PreDown notes:
#   - FORWARD rules allow traffic from/to wg0 to be routed through the container.
#   - MASQUERADE is scoped to -s 10.13.13.0/24 (the WireGuard tunnel subnet).
#     A broad "-o eth0 -j MASQUERADE" (no source) also masquerades WireGuard's
#     own handshake packets, which creates conntrack entries that conflict with
#     Docker's port-forwarding DNAT.  The conflict causes Linux MASQUERADE to
#     assign a random ephemeral source port (not 51820) to server-initiated
#     handshakes; the client responds to that ephemeral port, Docker has no
#     forwarding rule for it, the response is dropped, and neither side ever
#     completes the handshake — an infinite 5-second retry loop.
#     Scoping to 10.13.13.0/24 ensures only tunnelled client traffic is
#     masqueraded; WireGuard control-plane packets are left to Docker's own
#     conntrack, which handles them correctly.
#   - PREROUTING DNAT intercepts DNS (port 53) from wg0 and redirects to 1.1.1.1
#     so the client can use 10.13.13.1 as its DNS (always reachable via the tunnel).
#   - "; true" at the end ensures wg-quick always exits 0 even if some iptables
#     commands fail (e.g. iptable_nat module not yet loaded), preventing a
#     container restart loop that would break handshakes.

mkdir -p "${SCRIPT_DIR}/wireguard"
rm -rf "${SCRIPT_DIR}/wireguard/wg0.conf"
cat > "${SCRIPT_DIR}/wireguard/wg0.conf" <<EOF
[Interface]
PrivateKey   = ${WG_SERVER_PRIVATE}
Address      = 10.13.13.1/24
ListenPort   = ${WG_PORT}
MTU          = 1420
SaveConfig   = false
PostUp       = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.13.13.0/24 -o eth0 -j MASQUERADE; iptables -t nat -A PREROUTING -i %i -p udp --dport 53 -j DNAT --to 1.1.1.1; iptables -t nat -A PREROUTING -i %i -p tcp --dport 53 -j DNAT --to 1.1.1.1; true
PreDown      = iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null; iptables -D FORWARD -o %i -j ACCEPT 2>/dev/null; iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -o eth0 -j MASQUERADE 2>/dev/null; iptables -t nat -D PREROUTING -i %i -p udp --dport 53 -j DNAT --to 1.1.1.1 2>/dev/null; iptables -t nat -D PREROUTING -i %i -p tcp --dport 53 -j DNAT --to 1.1.1.1 2>/dev/null; true

[Peer]
# peer1
PublicKey    = ${WG_CLIENT_PUBLIC}
PresharedKey = ${WG_PSK}
AllowedIPs   = ${WG_CLIENT_IP}/32
EOF
chmod 600 "${SCRIPT_DIR}/wireguard/wg0.conf"

# ── Write client config ───────────────────────────────────────────────────────

rm -rf "${SCRIPT_DIR}/wireguard/peer1.conf"
cat > "${SCRIPT_DIR}/wireguard/peer1.conf" <<EOF
[Interface]
PrivateKey = ${WG_CLIENT_PRIVATE}
Address    = ${WG_CLIENT_IP}/24
DNS        = 10.13.13.1
MTU        = 1420

[Peer]
PublicKey           = ${WG_SERVER_PUBLIC}
PresharedKey        = ${WG_PSK}
AllowedIPs          = 0.0.0.0/0
Endpoint            = ${SERVER_IP}:${WG_PORT}
PersistentKeepalive = 25
EOF
chmod 600 "${SCRIPT_DIR}/wireguard/peer1.conf"

# ── Write to .env ─────────────────────────────────────────────────────────────
# Only writes keys for fresh install / --force. --update-config re-writes the
# same values (harmless), keeping .env consistent.

env_write SERVER_IP              "$SERVER_IP"
env_write WG_PORT                "$WG_PORT"
env_write WG_SERVER_PUBLIC_KEY   "$WG_SERVER_PUBLIC"
env_write WG_CLIENT_PRIVATE_KEY  "$WG_CLIENT_PRIVATE"
env_write WG_CLIENT_PUBLIC_KEY   "$WG_CLIENT_PUBLIC"
env_write WG_PSK                 "$WG_PSK"
env_write WG_CLIENT_IP           "$WG_CLIENT_IP"

if [[ "$UPDATE_CONFIG" == true ]]; then
  log_ok "WireGuard configs updated (keys unchanged)."
  if command -v docker >/dev/null 2>&1; then
    log_info "Restarting WireGuard container to apply changes..."
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d --force-recreate wireguard
    log_ok "WireGuard container restarted."
  else
    log_warn "docker not found — restart manually: docker compose up -d --force-recreate wireguard"
  fi
else
  log_ok "WireGuard configured (client IP: ${WG_CLIENT_IP}, port: ${WG_PORT})"
  [[ "$FORCE" == true ]] && \
    log_warn "Keys were regenerated — re-download the client config from the credentials page."
fi

# Re-render credentials page so new/updated configs are immediately available.
RENDER_SCRIPT="${SCRIPT_DIR}/render-credentials-page.sh"
if [[ -f "$RENDER_SCRIPT" ]]; then
  log_info "Re-rendering credentials page..."
  "$RENDER_SCRIPT" && log_ok "Credentials page updated." \
    || log_warn "Credentials page render failed — run ./render-credentials-page.sh manually."
fi
