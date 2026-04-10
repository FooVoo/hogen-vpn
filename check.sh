#!/usr/bin/env bash
# VPN health-check — probes each service and writes status to $WEBROOT/check/.
# Run every 60 s by vpn-health-check.timer (installed by setup-nginx.sh).
# Outputs:
#   $WEBROOT/check/index.html  — human-readable status page (auto-refreshes)
#   $WEBROOT/check/status.json — machine-readable JSON for external monitors
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

[[ -f "$ENV_FILE" ]] || { log_error ".env not found — run generate-secrets.sh first"; exit 1; }
set -a; source "$ENV_FILE"; set +a

WEBROOT="${CREDENTIALS_WEBROOT:-/var/www/vpn}"
CHECK_DIR="${WEBROOT}/check"
mkdir -p "$CHECK_DIR"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Which optional profiles are enabled (same default as setup-nginx.sh)
COMPOSE_PROFILES="${COMPOSE_PROFILES:-xray,ikev2,wireguard,monitoring}"
_profile_enabled() { [[ ",$COMPOSE_PROFILES," == *",$1,"* ]]; }

# ── Probes ──────────────────────────────────────────────────────────────────

# TCP port reachability using bash's /dev/tcp (no nc dependency)
check_tcp() {
  local port="$1"
  timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null && echo "up" || echo "down"
}

# Docker Compose service has at least one running container
check_service() {
  local cid
  cid=$(docker compose -f "${SCRIPT_DIR}/docker-compose.yml" ps -q "$1" 2>/dev/null | head -1)
  [[ -n "$cid" ]] && echo "up" || echo "down"
}

# Detect active MTProxy backend from COMPOSE_PROFILES.
# The mtg and telemt services are mutually exclusive (share host port 2083).
# Fall back to mtg probes if neither profile is set (legacy deployments).
MTG_PORT="${MTG_PORT:-2083}"
if _profile_enabled telemt; then
  MTG_TCP=$(check_tcp "$MTG_PORT")
  MTG_CTR=$(check_service telemt)
  _MTG_LABEL="MTProxy/telemt"
  _MTG_CHECK="tcp:${MTG_PORT}"
else
  MTG_TCP=$(check_tcp 2083)
  MTG_CTR=$(check_service mtg)
  _MTG_LABEL="MTProxy (Telegram)"
  _MTG_CHECK="tcp:2083"
fi

# Optional-service probes — only run when the profile is enabled
XRAY_TCP="" SS_TCP="" XRAY_CTR="" IPSEC_CTR="" WG_CTR=""
if _profile_enabled xray; then
  XRAY_TCP=$(check_tcp 8443)
  SS_TCP=$(check_tcp 8388)
  XRAY_CTR=$(check_service xray)
fi
_profile_enabled ikev2     && IPSEC_CTR=$(check_service ipsec)
_profile_enabled wireguard && WG_CTR=$(check_service wireguard)

# Overall: degraded if any enabled check fails
_check_statuses=("$MTG_TCP" "$MTG_CTR")
_profile_enabled xray      && _check_statuses+=("$XRAY_TCP" "$SS_TCP" "$XRAY_CTR")
_profile_enabled ikev2     && _check_statuses+=("$IPSEC_CTR")
_profile_enabled wireguard && _check_statuses+=("$WG_CTR")

OVERALL="ok"
for s in "${_check_statuses[@]}"; do
  [[ "$s" == "down" ]] && { OVERALL="degraded"; break; }
done
OVERALL_UP=$(echo "$OVERALL" | tr '[:lower:]' '[:upper:]')

# ── HTML ─────────────────────────────────────────────────────────────────────

# Emits one <tr> row
_row() {
  local name="$1" check="$2" status="$3"
  local status_up
  status_up=$(echo "$status" | tr '[:lower:]' '[:upper:]')
  printf '      <tr><td>%s</td><td class="dim">%s</td><td class="%s">%s</td></tr>\n' \
    "$name" "$check" "$status" "$status_up"
}

# Pre-build table rows so optional services are omitted when disabled
_tbody=""
_tbody+="$(_row "${_MTG_LABEL}"        "${_MTG_CHECK}"  "$MTG_TCP")"$'\n'
_tbody+="$(_row 'MTProxy container'   'docker compose' "$MTG_CTR")"$'\n'
if _profile_enabled xray; then
  _tbody+="$(_row 'VLESS + Reality'   'tcp:8443'       "$XRAY_TCP")"$'\n'
  _tbody+="$(_row 'Shadowsocks 2022'  'tcp:8388'       "$SS_TCP")"$'\n'
  _tbody+="$(_row 'Xray container'    'docker compose' "$XRAY_CTR")"$'\n'
fi
_profile_enabled ikev2     && _tbody+="$(_row 'IKEv2 / IPSec' 'docker compose' "$IPSEC_CTR")"$'\n'
_profile_enabled wireguard && _tbody+="$(_row 'WireGuard'      'docker compose' "$WG_CTR")"$'\n'

# Pre-build JSON services object
_json_svc="\"mtproxy\": { \"tcp_${MTG_PORT}\": \"${MTG_TCP}\", \"container\": \"${MTG_CTR}\" }"
if _profile_enabled xray; then
  _json_svc+=", \"vless\": { \"tcp_8443\": \"${XRAY_TCP}\", \"container\": \"${XRAY_CTR}\" }"
  _json_svc+=", \"shadowsocks\": { \"tcp_8388\": \"${SS_TCP}\",   \"container\": \"${XRAY_CTR}\" }"
fi
_profile_enabled ikev2     && _json_svc+=", \"ikev2\": { \"container\": \"${IPSEC_CTR}\" }"
_profile_enabled wireguard && _json_svc+=", \"wireguard\": { \"container\": \"${WG_CTR}\" }"

cat > "${CHECK_DIR}/index.html" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta http-equiv="refresh" content="60">
  <title>VPN Status</title>
  <style>
    *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
    body{font-family:system-ui,-apple-system,sans-serif;background:#0f1117;color:#e2e8f0;padding:28px 20px 56px;font-size:14px}
    h1{font-size:18px;font-weight:600;color:#f1f5f9;margin-bottom:18px}
    .badge{display:inline-block;padding:5px 14px;border-radius:20px;font-weight:700;font-size:13px;letter-spacing:.5px;margin-bottom:28px}
    .badge.ok{background:#14532d;color:#4ade80}
    .badge.degraded{background:#7f1d1d;color:#f87171}
    table{border-collapse:collapse;width:100%;max-width:540px}
    th{text-align:left;font-size:11px;text-transform:uppercase;letter-spacing:.8px;color:#475569;padding-bottom:10px}
    th:last-child{text-align:right}
    td{padding:9px 0;border-top:1px solid #1e2535;color:#cbd5e1}
    td:last-child{text-align:right}
    .dim{color:#475569;font-size:12px}
    .up{color:#4ade80;font-weight:700}
    .down{color:#f87171;font-weight:700}
    .footer{margin-top:28px;font-size:12px;color:#334155}
  </style>
</head>
<body>
  <h1>VPN Status</h1>
  <div class="badge ${OVERALL}">${OVERALL_UP}</div>
  <table>
    <thead>
      <tr><th>Service</th><th>Check</th><th>Status</th></tr>
    </thead>
    <tbody>
${_tbody}    </tbody>
  </table>
  <p class="footer">Last checked: ${TIMESTAMP} &nbsp;·&nbsp; auto-refreshes every 60 s</p>
</body>
</html>
HTML

# ── JSON ─────────────────────────────────────────────────────────────────────

cat > "${CHECK_DIR}/status.json" <<JSON
{
  "status": "${OVERALL}",
  "checked_at": "${TIMESTAMP}",
  "services": { ${_json_svc} }
}
JSON

chmod 644 "${CHECK_DIR}/index.html" "${CHECK_DIR}/status.json"

# ── .check_env ────────────────────────────────────────────────────────────────
# Written for render-credentials-page.sh to embed status in the credentials page.

cat > "${SCRIPT_DIR}/.check_env" <<ENV
CHECK_OVERALL=${OVERALL}
CHECK_TIMESTAMP=${TIMESTAMP}
CHECK_MTG_TCP=${MTG_TCP}
CHECK_MTG_CTR=${MTG_CTR}
CHECK_XRAY_TCP=${XRAY_TCP}
CHECK_SS_TCP=${SS_TCP}
CHECK_XRAY_CTR=${XRAY_CTR}
CHECK_IPSEC_CTR=${IPSEC_CTR}
CHECK_WG_CTR=${WG_CTR}
ENV
chmod 600 "${SCRIPT_DIR}/.check_env"

# Re-render the credentials page so the embedded status card stays fresh.
"${SCRIPT_DIR}/render-credentials-page.sh" "$WEBROOT" || true
