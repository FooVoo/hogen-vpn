#!/usr/bin/env bash
# vpn-logs.sh — tail systemd journals and Docker container logs for hogen-vpn.
#
# Usage:
#   ./vpn-logs.sh                          # last 50 lines of all logs
#   ./vpn-logs.sh -f                       # follow all logs
#   ./vpn-logs.sh -n 200                   # last 200 lines
#   ./vpn-logs.sh --since "1 hour ago"
#   ./vpn-logs.sh rotate|check|docker      # filter by service group
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

# ── argument parsing ──────────────────────────────────────────────────────────

JOURNAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      sed -n '/^# Usage:/,/^[^#]/{ /^#/p }' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) JOURNAL_ARGS+=("$1") ;;
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

# ── journal ───────────────────────────────────────────────────────────────────

_run_journal() {
  local FOLLOW=false LINES=50 SINCE="" SERVICE="all"

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
  local DOCKER_SERVICES=(mtg xray ipsec wireguard)
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

    [[ ${#pids[@]} -gt 0 ]] || { log_error "Nothing to follow for service group: ${SERVICE}"; exit 1; }
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

_run_journal
