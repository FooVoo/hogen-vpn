#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

ENV_FILE="${SCRIPT_DIR}/.env"

[[ -f "$ENV_FILE" ]] || { log_error ".env not found — run generate-secrets.sh first"; exit 1; }

set -a; source "$ENV_FILE"; set +a

[[ -n "${XRAY_UUID:-}" ]]        || { log_error "XRAY_UUID is missing in .env"; exit 1; }
[[ -n "${XRAY_PRIVATE_KEY:-}" ]] || { log_error "XRAY_PRIVATE_KEY is missing in .env"; exit 1; }
[[ -n "${XRAY_SHORT_ID:-}" ]]    || { log_error "XRAY_SHORT_ID is missing in .env"; exit 1; }
[[ -n "${XRAY_SNI:-}" ]]         || { log_error "XRAY_SNI is missing in .env"; exit 1; }
[[ -n "${XRAY_DEST:-}" ]]        || { log_error "XRAY_DEST is missing in .env"; exit 1; }
[[ -n "${SS_PASSWORD:-}" ]]      || { log_error "SS_PASSWORD is missing in .env"; exit 1; }
[[ -n "${SS_METHOD:-}" ]]        || { log_error "SS_METHOD is missing in .env"; exit 1; }
[[ -n "${SS_PORT:-}" ]]          || { log_error "SS_PORT is missing in .env"; exit 1; }

# For Shadowsocks 2022 methods the password must be a base64-encoded key of the correct size.
if [[ "${SS_METHOD}" == 2022-* ]]; then
    case "${SS_METHOD}" in
        *-aes-128-gcm)          _required_bytes=16 ;;
        *-aes-256-gcm)          _required_bytes=32 ;;
        *-chacha20-poly1305)    _required_bytes=32 ;;
        *) log_error "Unrecognised Shadowsocks 2022 method: ${SS_METHOD}"; exit 1 ;;
    esac
    _actual_bytes=$(printf '%s' "${SS_PASSWORD}" | base64 -d 2>/dev/null | wc -c | tr -d '[:space:]')
    [[ "${_actual_bytes}" -eq "${_required_bytes}" ]] || {
        log_error "SS_PASSWORD for ${SS_METHOD} must decode to ${_required_bytes} bytes (got ${_actual_bytes})"
        exit 1
    }
fi

mkdir -p "${SCRIPT_DIR}/xray"
cat > "${SCRIPT_DIR}/xray/config.json" <<EOF
{
    "log": { "loglevel": "warning" },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": 8443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${XRAY_UUID}",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "${XRAY_DEST}",
                    "serverNames": ["${XRAY_SNI}"],
                    "privateKey": "${XRAY_PRIVATE_KEY}",
                    "shortIds": ["${XRAY_SHORT_ID}"],
                    "maxTimeDiff": 60000
                }
            }
        },
        {
            "listen": "0.0.0.0",
            "port": ${SS_PORT},
            "protocol": "shadowsocks",
            "settings": {
                "method": "${SS_METHOD}",
                "password": "${SS_PASSWORD}",
                "network": "tcp,udp"
            }
        }
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "ip": ["geoip:private"],
                "outboundTag": "block"
            }
        ]
    },
    "outbounds": [
        { "protocol": "freedom", "tag": "direct" },
        { "protocol": "blackhole", "tag": "block" }
    ]
}
EOF
chmod 644 "${SCRIPT_DIR}/xray/config.json"
log_ok "xray/config.json written (SNI: ${XRAY_SNI}, SS method: ${SS_METHOD})"
