#!/usr/bin/env bash
# netdata/vpn.chart.sh — Netdata charts.d plugin for hogen-vpn.
#
# Exposes two charts to the Netdata dashboard:
#   vpn.ports         — TCP connectivity to each VPN port (1=up, 0=down)
#   vpn.rotation_age  — Minutes since the last cover-domain rotation
#
# Install (done by setup-nginx.sh):
#   install -m 755 netdata/vpn.chart.sh /usr/lib/netdata/charts.d/vpn.chart.sh
#   install -m 644 netdata/health.d/vpn.conf /etc/netdata/health.d/vpn.conf
#   echo "VPN_DIR=${SCRIPT_DIR}" > /etc/netdata/charts.d/vpn.conf
#
# The netdata user must be in the docker group to run docker compose commands.

# Seconds between chart updates. Keep in sync with charts.d.conf if overridden.
vpn_update_every=30

# VPN stack directory — overridden by /etc/netdata/charts.d/vpn.conf.
: "${VPN_DIR:=/opt/hogen-vpn}"

# Source per-deployment config (written by setup-nginx.sh).
# shellcheck disable=SC1091
[[ -f /etc/netdata/charts.d/vpn.conf ]] && source /etc/netdata/charts.d/vpn.conf

# ── charts.d lifecycle callbacks ─────────────────────────────────────────────

vpn_check() {
  [[ -d "$VPN_DIR" ]] || return 1
  return 0
}

vpn_create() {
  cat <<CHARTS
CHART vpn.ports '' 'VPN Port Connectivity' 'status' 'ports' vpn.ports line 1000 ${vpn_update_every}
DIMENSION p443  'HTTPS :443'        absolute 1 1
DIMENSION p8443 'VLESS :8443'       absolute 1 1
DIMENSION p2083 'MTProxy :2083'     absolute 1 1
DIMENSION p8388 'Shadowsocks :8388' absolute 1 1
DIMENSION pwg   'WireGuard ctr'     absolute 1 1

CHART vpn.rotation_age '' 'Time Since Last Rotation' 'minutes' 'rotation' vpn.rotation_age area 1001 ${vpn_update_every}
DIMENSION xray 'Xray / VLESS' absolute 1 1
DIMENSION mtg  'MTProxy'      absolute 1 1
CHARTS
  return 0
}

vpn_update() {
  local _t="$1"

  # TCP port probes via bash built-in /dev/tcp — no external tools needed.
  _tcp_up() { timeout 2 bash -c "echo >/dev/tcp/127.0.0.1/${1}" 2>/dev/null && echo 1 || echo 0; }

  # WireGuard uses UDP; probe container status instead of a TCP port check.
  _ctr_up() {
    local cid
    cid=$(docker compose -f "${VPN_DIR}/docker-compose.yml" ps -q "$1" 2>/dev/null | head -1)
    [[ -n "$cid" ]] && echo 1 || echo 0
  }

  local p443 p8443 p2083 p8388 pwg
  p443=$(_tcp_up 443)
  p8443=$(_tcp_up 8443)
  p2083=$(_tcp_up 2083)
  p8388=$(_tcp_up 8388)
  pwg=$(_ctr_up wireguard)

  # Rotation age: seconds between recorded timestamp and now, converted to minutes.
  _age_mins() {
    local f="$1"
    [[ -f "$f" ]] || { echo 0; return; }
    local ts epoch
    ts=$(< "$f")
    epoch=$(date -d "$ts" +%s 2>/dev/null) || { echo 0; return; }
    echo $(( ( $(date +%s) - epoch ) / 60 ))
  }

  local age_xray age_mtg
  age_xray=$(_age_mins "${VPN_DIR}/.last_xray_rotation")
  age_mtg=$(_age_mins "${VPN_DIR}/.last_mtg_rotation")

  cat <<DATA
BEGIN vpn.ports ${_t}
SET p443  = ${p443}
SET p8443 = ${p8443}
SET p2083 = ${p2083}
SET p8388 = ${p8388}
SET pwg   = ${pwg}
END

BEGIN vpn.rotation_age ${_t}
SET xray = ${age_xray}
SET mtg  = ${age_mtg}
END
DATA
  return 0
}
