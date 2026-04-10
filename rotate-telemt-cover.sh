#!/usr/bin/env bash
# rotate-telemt-cover.sh — rotate the FakeTLS cover domain for telemt.
#
# Unlike mtg rotation (which regenerates the whole ee-secret), telemt only
# needs the tls_domain patched in config.toml — the raw key is preserved, so
# existing user links stay valid unless the host port also changes.
#
# Run manually or install as a systemd timer (see telemt-migration.md §9).
#
# Note: with tls_domains listing all 35 pool domains simultaneously (Option A
# in the migration guide), this rotation is not required. Run it only if you
# want to pin a single domain at a time and rotate on a schedule.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
CONFIG="${SCRIPT_DIR}/telemt/config.toml"

# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/cover-domains.sh
source "${SCRIPT_DIR}/lib/cover-domains.sh"

[[ -f "$ENV_FILE" ]] || { log_error ".env not found"; exit 1; }
[[ -f "$CONFIG" ]]   || { log_error "telemt/config.toml not found — run setup-telemt.sh first"; exit 1; }

set -a; source "$ENV_FILE"; set +a

[[ -n "${MTG_SECRET:-}" ]]      || { log_error "MTG_SECRET missing in .env"; exit 1; }
[[ -n "${MTG_PORT:-}" ]]        || { log_error "MTG_PORT missing in .env"; exit 1; }
[[ -n "${SERVER_IP:-}" ]]       || { log_error "SERVER_IP missing in .env"; exit 1; }

CURRENT="${MTG_COVER_DOMAIN:-}"

# Build candidate list (exclude current domain)
CANDIDATES=()
for D in "${COVER_DOMAINS[@]}"; do
  [[ -n "$D" && "$D" != "$CURRENT" ]] && CANDIDATES+=("$D")
done
(( ${#CANDIDATES[@]} > 0 )) || { log_error "No rotation candidates (pool exhausted?)"; exit 1; }

NEXT="${CANDIDATES[$RANDOM % ${#CANDIDATES[@]}]}"

# Patch tls_domain in telemt/config.toml
sed -i "s|^tls_domain *= *\"[^\"]*\"|tls_domain = \"${NEXT}\"|" "$CONFIG"

# Reconstruct MTG_SECRET and MTG_LINK with the new domain (raw key stays the same)
RAW_KEY="${MTG_SECRET:2:32}"
NEW_DOMAIN_HEX=$(python3 -c \
  "import binascii,sys; print(binascii.hexlify(sys.argv[1].encode()).decode())" \
  "$NEXT")
NEW_SECRET="ee${RAW_KEY}${NEW_DOMAIN_HEX}"
NEW_LINK="https://t.me/proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${NEW_SECRET}"

# Restart telemt to pick up the new tls_domain
docker compose -f "${SCRIPT_DIR}/docker-compose.yml" restart telemt >/dev/null

# Update .env atomically
TMP_ENV=$(mktemp "${ENV_FILE}.XXXXXX")
chmod 600 "$TMP_ENV"
trap 'rm -f "$TMP_ENV"' EXIT
grep -v -E '^(MTG_COVER_DOMAIN|MTG_SECRET|MTG_LINK)=' "$ENV_FILE" > "$TMP_ENV"
printf 'MTG_COVER_DOMAIN=%s\n'   "$NEXT"       >> "$TMP_ENV"
printf 'MTG_SECRET=%s\n'         "$NEW_SECRET" >> "$TMP_ENV"
printf 'MTG_LINK="%s"\n'         "$NEW_LINK"   >> "$TMP_ENV"
mv "$TMP_ENV" "$ENV_FILE"

"${SCRIPT_DIR}/render-credentials-page.sh" "${CREDENTIALS_WEBROOT:-/var/www/vpn}"
date '+%Y-%m-%d %H:%M %Z' > "${SCRIPT_DIR}/.last_mtg_rotation"
log_ok "Telemt cover domain: ${CURRENT} → ${NEXT}"
