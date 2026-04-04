#!/usr/bin/env bash
set -euo pipefail

SERVER="root@universal.ramilkarimov.me"
REMOTE_DIR="/opt/vpn"
KEY="$HOME/.ssh/vpn_deploy"

rsync -az --delete -e "ssh -i $KEY" \
  --exclude='.env' \
  --exclude='mtg/config.toml' \
  --exclude='xray/config.json' \
  --exclude='web/index.html' \
  --exclude='web/.htpasswd' \
  ./ "${SERVER}:${REMOTE_DIR}/"

ssh -i "$KEY" "$SERVER" "chmod +x ${REMOTE_DIR}/*.sh"

echo "Synced → ${SERVER}:${REMOTE_DIR}"

echo "Re-rendering configs on server..."
ssh -i "$KEY" "$SERVER" "cd ${REMOTE_DIR} && ./render-xray-config.sh && ./render-credentials-page.sh"

echo "Restarting containers..."
ssh -i "$KEY" "$SERVER" "cd ${REMOTE_DIR} && docker compose up -d --force-recreate"

echo "Deploy complete."
