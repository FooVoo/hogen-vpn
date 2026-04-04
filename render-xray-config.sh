#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

[[ -f "$ENV_FILE" ]] || { echo "ERROR: .env not found — run generate-secrets.sh first"; exit 1; }

set -a; source "$ENV_FILE"; set +a

[[ -n "${XRAY_UUID:-}" ]]        || { echo "ERROR: XRAY_UUID is missing"; exit 1; }
[[ -n "${XRAY_PRIVATE_KEY:-}" ]] || { echo "ERROR: XRAY_PRIVATE_KEY is missing"; exit 1; }
[[ -n "${XRAY_SHORT_ID:-}" ]]    || { echo "ERROR: XRAY_SHORT_ID is missing"; exit 1; }
[[ -n "${XRAY_SNI:-}" ]]         || { echo "ERROR: XRAY_SNI is missing"; exit 1; }
[[ -n "${XRAY_DEST:-}" ]]        || { echo "ERROR: XRAY_DEST is missing"; exit 1; }
[[ -n "${SS_PASSWORD:-}" ]]      || { echo "ERROR: SS_PASSWORD is missing"; exit 1; }
[[ -n "${SS_METHOD:-}" ]]        || { echo "ERROR: SS_METHOD is missing"; exit 1; }
[[ -n "${SS_PORT:-}" ]]          || { echo "ERROR: SS_PORT is missing"; exit 1; }

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
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
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
    "outbounds": [
        { "protocol": "freedom", "tag": "direct" },
        { "protocol": "blackhole", "tag": "block" }
    ]
}
EOF
