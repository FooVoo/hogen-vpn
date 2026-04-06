#!/usr/bin/env bash
# vpn-logs.sh — VPN monitoring via Netdata REST API with journal fallback.
#
# Usage:
#   ./vpn-logs.sh                     # Netdata: port status + active alerts
#   ./vpn-logs.sh --alerts            # active Netdata alerts only
#   ./vpn-logs.sh --url               # print Netdata dashboard URL and exit
#   ./vpn-logs.sh --journal           # raw journal + docker logs (last 50 lines)
#   ./vpn-logs.sh --journal -f        # follow journal logs
#   ./vpn-logs.sh --journal -n 200    # last 200 lines
#   ./vpn-logs.sh --journal --since "1 hour ago"
#   ./vpn-logs.sh --journal rotate|check|docker
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

NETDATA_URL="${NETDATA_URL:-http://localhost:19999}"

# ── argument parsing ──────────────────────────────────────────────────────────

MODE="netdata"   # netdata | alerts | url | journal
JOURNAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --journal|-j)  MODE="journal" ;;
    --alerts)      MODE="alerts" ;;
    --url)         MODE="url" ;;
    -h|--help)
      sed -n '/^# Usage:/,/^[^#]/{ /^#/p }' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    # Pass remaining args through to the journal sub-mode
    *)  JOURNAL_ARGS+=("$1") ;;
  esac
  shift
done

# ── ANSI helpers ──────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_HEAD=$'\033[1;34m'
  C_OK=$'\033[32m'
  C_WARN=$'\033[33m'
  C_ERR=$'\033[31m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_HEAD='' C_OK='' C_WARN='' C_ERR=''
fi

_section() {
  printf '\n%s── %s ──%s\n' "$C_HEAD" "$1" "$C_RESET"
}

# ── Netdata API helpers ───────────────────────────────────────────────────────

_api() {
  curl -sf --max-time 5 "${NETDATA_URL}${1}" 2>/dev/null
}

_netdata_up() {
  _api "/api/v1/info" >/dev/null 2>&1
}

# Parse a simple flat JSON key:value from Netdata responses with Python3.
_py_parse() {
  python3 -c "$1" 2>/dev/null
}

# Show current values for vpn.ports and vpn.rotation_age charts.
_show_charts() {
  _section "VPN port connectivity (vpn.ports)"

  local raw
  raw=$(_api "/api/v1/data?chart=vpn.ports&points=1&after=-60&format=json") || {
    printf '%s(chart not available — vpn.chart.sh may not be loaded yet)%s\n' "$C_DIM" "$C_RESET"
    return
  }

  _py_parse "
import json, sys
d = json.loads('''${raw}''')
labels = d['labels'][1:]   # skip 'time'
values = d['data'][0][1:]  # skip timestamp
for name, val in zip(labels, values):
    status = 'UP' if val == 1 else 'DOWN'
    colour = '\033[32m' if val == 1 else '\033[31m'
    print(f'  {colour}{status}\033[0m  {name}')
"

  _section "Rotation age (vpn.rotation_age)"

  raw=$(_api "/api/v1/data?chart=vpn.rotation_age&points=1&after=-60&format=json") || {
    printf '%s(chart not available)%s\n' "$C_DIM" "$C_RESET"
    return
  }

  _py_parse "
import json, sys
d = json.loads('''${raw}''')
labels = d['labels'][1:]
values = d['data'][0][1:]
for name, val in zip(labels, values):
    age = int(val) if val is not None else 0
    colour = '\033[32m' if age < 45 else ('\033[33m' if age < 90 else '\033[31m')
    print(f'  {colour}{age:3d} min\033[0m  {name}')
"
}

# Show active Netdata alerts filtered to VPN-related ones.
_show_alerts() {
  _section "Active Netdata alerts"

  local raw
  raw=$(_api "/api/v1/alarms") || {
    printf '%s(could not reach Netdata API)%s\n' "$C_DIM" "$C_RESET"
    return
  }

  local count
  count=$(_py_parse "
import json, sys
d = json.loads('''${raw}''')
alarms = d.get('alarms', {})
vpn = {k: v for k, v in alarms.items() if 'vpn' in k.lower() or 'vpn' in v.get('chart','').lower()}
if not vpn:
    print('OK  No active VPN alerts')
else:
    for name, a in vpn.items():
        st = a.get('status', '?')
        colour = '\033[31m' if st == 'CRITICAL' else ('\033[33m' if st == 'WARNING' else '\033[32m')
        print(f\"  {colour}{st:10s}\033[0m  {a.get('name',name)}: {a.get('info','')}\")
print(len(vpn))
" | tee /dev/stderr | tail -1) 2>&1 || count=0

  # Re-run without the count suffix for clean output
  _py_parse "
import json, sys
d = json.loads('''${raw}''')
alarms = d.get('alarms', {})
vpn = {k: v for k, v in alarms.items() if 'vpn' in k.lower() or 'vpn' in v.get('chart','').lower()}
if not vpn:
    print('  ${C_OK}OK${C_RESET}  No active VPN alerts')
else:
    for name, a in vpn.items():
        st = a.get('status', '?')
        colour = '\033[31m' if st in ('CRITICAL','CRIT') else ('\033[33m' if st == 'WARNING' else '\033[32m')
        print(f\"  {colour}{st:10s}\033[0m  {a.get('name',name)}: {a.get('info','')}\")
"
}

# ── journal sub-mode (original behaviour) ─────────────────────────────────────

_run_journal() {
  # Re-exec with the original journal logic inline, passing through JOURNAL_ARGS.
  local FOLLOW=false LINES=50 SINCE="" SERVICE="all"

  for arg in "${JOURNAL_ARGS[@]:-}"; do : ; done  # silence SC2034 on empty array

  local i=0 args=("${JOURNAL_ARGS[@]:-}")
  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
      -f|--follow)  FOLLOW=true ;;
      -n|--lines)   (( i++ )); LINES="${args[$i]}" ;;
      --since)      (( i++ )); SINCE="${args[$i]}" ;;
      all|rotate|check|docker) SERVICE="${args[$i]}" ;;
    esac
    (( i++ ))
  done

  local SYSTEMD_UNITS=(
    "vpn-health-check.service"
    "vpn-reality-cover-rotate.service"
    "vpn-mtg-rotate.service"
    "hogen-vpn.service"
  )
  local DOCKER_SERVICES=(mtg xray ipsec)
  local COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

  _unit_flags() {
    local flags=()
    case "$SERVICE" in
      check)  flags=(-u vpn-health-check.service) ;;
      rotate) flags=(-u vpn-reality-cover-rotate.service -u vpn-mtg-rotate.service) ;;
      docker) ;;
      *)      for u in "${SYSTEMD_UNITS[@]}"; do flags+=(-u "$u"); done ;;
    esac
    printf '%s\n' "${flags[@]:-}"
  }

  _has_docker() {
    [[ "$SERVICE" == "docker" || "$SERVICE" == "all" ]] && \
    [[ -f "$COMPOSE_FILE" ]] && command -v docker >/dev/null 2>&1
  }

  if $FOLLOW; then
    local pids=()
    _cleanup() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
    trap _cleanup EXIT INT TERM

    local j_flags=()
    mapfile -t j_flags < <(_unit_flags)

    if [[ ${#j_flags[@]} -gt 0 ]]; then
      local jctl_args=(--no-pager --output=short-iso -n "$LINES" --follow)
      [[ -n "$SINCE" ]] && jctl_args+=(--since "$SINCE")
      printf '%s→ Following systemd journals (%s)…%s\n' "$C_BOLD" "$SERVICE" "$C_RESET"
      journalctl "${jctl_args[@]}" "${j_flags[@]}" 2>/dev/null &
      pids+=($!)
    fi

    if _has_docker; then
      printf '%s→ Following docker container logs…%s\n' "$C_BOLD" "$C_RESET"
      docker compose -f "$COMPOSE_FILE" logs --follow --no-log-prefix -n "$LINES" \
        "${DOCKER_SERVICES[@]}" 2>/dev/null &
      pids+=($!)
    fi

    [[ ${#pids[@]} -gt 0 ]] || { printf 'Nothing to follow for %s\n' "$SERVICE" >&2; exit 1; }
    printf '%sPress Ctrl-C to stop.%s\n' "$C_DIM" "$C_RESET"
    wait

  else
    local j_flags=()
    mapfile -t j_flags < <(_unit_flags)

    if [[ ${#j_flags[@]} -gt 0 ]]; then
      _section "Systemd journals  (last ${LINES} lines)"
      local jctl_args=(--no-pager --output=short-iso -n "$LINES")
      [[ -n "$SINCE" ]] && jctl_args+=(--since "$SINCE")
      journalctl "${jctl_args[@]}" "${j_flags[@]}" 2>/dev/null || \
        printf '%s(no journal entries)%s\n' "$C_DIM" "$C_RESET"
    fi

    if _has_docker; then
      _section "Docker container logs  (last ${LINES} lines)"
      docker compose -f "$COMPOSE_FILE" logs --no-log-prefix -n "$LINES" \
        "${DOCKER_SERVICES[@]}" 2>/dev/null || \
        printf '%s(no docker logs)%s\n' "$C_DIM" "$C_RESET"
    fi
  fi
}

# ── entry point ───────────────────────────────────────────────────────────────

case "$MODE" in
  url)
    # Try to read CREDENTIALS_DOMAIN from .env for the public HTTPS URL.
    local public_url="$NETDATA_URL"
    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
      local _domain
      _domain=$(grep -E '^CREDENTIALS_DOMAIN=' "${SCRIPT_DIR}/.env" | cut -d= -f2- | tr -d '"')
      [[ -n "$_domain" ]] && public_url="https://${_domain}/net-data/"
    fi
    printf 'Netdata dashboard: %s%s%s\n' "$C_BOLD" "$public_url" "$C_RESET"
    printf 'Credentials:       admin / <your PAGE_TOKEN>\n'
    printf 'Local API:         %s\n' "$NETDATA_URL"
    ;;
  alerts)
    if ! _netdata_up; then
      printf '%sNetdata is not running. Start it with: systemctl start netdata%s\n' "$C_ERR" "$C_RESET" >&2
      exit 1
    fi
    _show_alerts
    ;;
  netdata)
    if ! _netdata_up; then
      printf '%sNetdata is not running — falling back to journal mode.%s\n' "$C_WARN" "$C_RESET" >&2
      printf 'Start Netdata:  systemctl start netdata\n' >&2
      printf 'Install plugin: see setup-nginx.sh\n\n' >&2
      _run_journal
    else
      printf '%sNetdata dashboard:%s %s\n' "$C_BOLD" "$C_RESET" "$NETDATA_URL"
      _show_charts
      _show_alerts
    fi
    ;;
  journal)
    _run_journal
    ;;
esac

