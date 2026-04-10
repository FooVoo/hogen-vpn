#!/usr/bin/env bash
# lib/log.sh — structured logging for hogen-vpn scripts.
#
# Source this file near the top of any script:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/log.sh"
#
# Logging functions (write to stdout/stderr → systemd journal):
#   log_info  MESSAGE
#   log_ok    MESSAGE
#   log_warn  MESSAGE
#   log_error MESSAGE
#
# The script name is auto-detected from BASH_SOURCE; override with LOG_PREFIX.
# Colors are emitted only when stdout/stderr is a terminal.

# Resolve the calling script's name once at source time.
_LOG_SCRIPT="${LOG_PREFIX:-$(basename "${BASH_SOURCE[${#BASH_SOURCE[@]}-1]}" .sh)}"

# ANSI palette — suppressed when not connected to a terminal.
if [[ -t 1 && -t 2 ]]; then
  _LC_RESET=$'\033[0m'
  _LC_DIM=$'\033[2m'
  _LC_INFO=$'\033[36m'   # cyan
  _LC_OK=$'\033[32m'     # green
  _LC_WARN=$'\033[33m'   # yellow
  _LC_ERROR=$'\033[31m'  # red
else
  _LC_RESET='' _LC_DIM='' _LC_INFO='' _LC_OK='' _LC_WARN='' _LC_ERROR=''
fi

# _log LEVEL COLOR MESSAGE
_log() {
  local level="$1" color="$2"
  shift 2
  printf '%s%-5s %s%-20s%s %s\n' \
    "$color" "$level" \
    "$_LC_DIM" "$_LOG_SCRIPT" \
    "$_LC_RESET${color}" \
    "$*${_LC_RESET}"
}

_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log_info()  { _log "INFO"  "$_LC_INFO"  "$(_ts) $*"; }
log_ok()    { _log "OK"    "$_LC_OK"    "$(_ts) $*"; }
log_warn()  { _log "WARN"  "$_LC_WARN"  "$(_ts) $*" >&2; }
log_error() { _log "ERROR" "$_LC_ERROR" "$(_ts) $*" >&2; }
