#!/usr/bin/env bash
# lib/env.sh — write or update a single key=value pair in .env
#
# Usage: source this file, then call:
#   env_write KEY VALUE
#
# Behaviour:
#   - Creates $SCRIPT_DIR/.env (chmod 600) if it does not exist.
#   - Replaces the existing KEY= line when KEY is already present.
#   - Appends KEY=VALUE otherwise.
#   - Values that contain shell-special characters, spaces, or URI schemes
#     are automatically double-quoted; simple alphanumeric values are not.
#
# SCRIPT_DIR must be set by the calling script before sourcing this file.

env_write() {
  local key="$1" value="$2"
  local file="${SCRIPT_DIR}/.env"
  local line

  # Quote if the value contains anything beyond plain word chars, dots, dashes,
  # or forward slashes (e.g. base64, URIs, passwords with special chars).
  if [[ "$value" =~ [^A-Za-z0-9_./:@-] ]]; then
    line="${key}=\"${value}\""
  else
    line="${key}=${value}"
  fi

  if [[ -f "$file" ]] && grep -qE "^${key}=" "$file"; then
    # Replace in-place: write all lines except the matching one, then append
    # the updated line.  Using a temp file avoids sed quoting pitfalls with
    # values that contain backslashes, ampersands, or delimiter characters.
    local tmp
    tmp=$(mktemp "${file}.XXXXXX")
    grep -v "^${key}=" "$file" > "$tmp"
    printf '%s\n' "$line" >> "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$file"
  else
    printf '%s\n' "$line" >> "$file"
    chmod 600 "$file"
  fi
}
