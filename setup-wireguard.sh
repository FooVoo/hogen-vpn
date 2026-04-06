#!/usr/bin/env bash
# setup-wireguard.sh — generate WireGuard credentials and write server/client configs.
#
# Writes:
#   wireguard/wg0.conf      — WireGuard server config (mounted :ro into the container)
#   wireguard/peer1.conf    — WireGuard client config (distributed via credentials page)
#   .env                    — WG_PORT, WG_SERVER_PUBLIC_KEY, WG_CLIENT_PRIVATE_KEY,
#                             WG_CLIENT_PUBLIC_KEY, WG_PSK, WG_CLIENT_IP
#
# Usage:
#   ./setup-wireguard.sh <SERVER_IP>
#   ./setup-wireguard.sh                    # reads SERVER_IP from existing .env
#   ./setup-wireguard.sh --force            # regenerate even if already configured
#   ./setup-wireguard.sh --server-ip=1.2.3.4
#
# After running this script (or regenerating with --force), restart the wireguard
# container so it picks up the new config:
#   docker compose up -d --force-recreate wireguard
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
    && grep -qE '^WG_SERVER_PUBLIC_KEY=' "${SCRIPT_DIR}/.env"; then
  log_info "WireGuard already configured. Use --force to regenerate."
  exit 0
fi

command -v docker >/dev/null 2>&1 || { log_error "docker is not installed"; exit 1; }

# ── WireGuard key generation ──────────────────────────────────────────────────

log_info "Generating WireGuard credentials..."

WG_PORT=51820
WG_CLIENT_IP="10.13.13.2"

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

# ── Write server config ───────────────────────────────────────────────────────
# Docker Compose creates missing bind-mount sources as directories; remove any
# such stale directory before writing the file.

mkdir -p "${SCRIPT_DIR}/wireguard"
rm -rf "${SCRIPT_DIR}/wireguard/wg0.conf"
cat > "${SCRIPT_DIR}/wireguard/wg0.conf" <<EOF
[Interface]
PrivateKey   = ${WG_SERVER_PRIVATE}
Address      = 10.13.13.1/24
ListenPort   = ${WG_PORT}
MTU          = 1420
SaveConfig   = false
PostUp       = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE; iptables -t nat -A PREROUTING -i %i -p udp --dport 53 -j DNAT --to 1.1.1.1; iptables -t nat -A PREROUTING -i %i -p tcp --dport 53 -j DNAT --to 1.1.1.1
PreDown      = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE; iptables -t nat -D PREROUTING -i %i -p udp --dport 53 -j DNAT --to 1.1.1.1; iptables -t nat -D PREROUTING -i %i -p tcp --dport 53 -j DNAT --to 1.1.1.1

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

env_write SERVER_IP              "$SERVER_IP"
env_write WG_PORT                "$WG_PORT"
env_write WG_SERVER_PUBLIC_KEY   "$WG_SERVER_PUBLIC"
env_write WG_CLIENT_PRIVATE_KEY  "$WG_CLIENT_PRIVATE"
env_write WG_CLIENT_PUBLIC_KEY   "$WG_CLIENT_PUBLIC"
env_write WG_PSK                 "$WG_PSK"
env_write WG_CLIENT_IP           "$WG_CLIENT_IP"

log_ok "WireGuard configured (client IP: ${WG_CLIENT_IP}, port: ${WG_PORT})"
