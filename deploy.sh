#!/usr/bin/env bash
set -euo pipefail

# Overridable via environment variables
DEPLOY_HOST="${DEPLOY_HOST:-root@universal.ramilkarimov.me}"
DEPLOY_REMOTE_DIR="${DEPLOY_REMOTE_DIR:-/opt/vpn}"
DEPLOY_KEY="${DEPLOY_KEY:-$HOME/.ssh/vpn_deploy}"

rsync -az --delete -e "ssh -i $DEPLOY_KEY -o StrictHostKeyChecking=accept-new" \
  --exclude='.env' \
  --exclude='mtg/config.toml' \
  --exclude='xray/config.json' \
  --exclude='ipsec/' \
  --exclude='web/index.html' \
  --exclude='web/.htpasswd' \
  ./ "${DEPLOY_HOST}:${DEPLOY_REMOTE_DIR}/"

ssh -i "$DEPLOY_KEY" -o StrictHostKeyChecking=accept-new "$DEPLOY_HOST" "chmod +x ${DEPLOY_REMOTE_DIR}/*.sh"

echo "Synced → ${DEPLOY_HOST}:${DEPLOY_REMOTE_DIR}"

echo "Re-rendering configs on server..."
ssh -i "$DEPLOY_KEY" -o StrictHostKeyChecking=accept-new "$DEPLOY_HOST" "cd ${DEPLOY_REMOTE_DIR} && ./render-xray-config.sh && ./render-credentials-page.sh"

echo "Restarting containers..."
ssh -i "$DEPLOY_KEY" -o StrictHostKeyChecking=accept-new "$DEPLOY_HOST" "cd ${DEPLOY_REMOTE_DIR} && docker compose up -d --force-recreate"

echo "Deploy complete."
