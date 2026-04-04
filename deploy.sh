#!/usr/bin/env bash
set -euo pipefail

# Overridable via environment variables
DEPLOY_HOST="${DEPLOY_HOST:-root@your-server.example.com}"
DEPLOY_REMOTE_DIR="${DEPLOY_REMOTE_DIR:-/opt/vpn}"
DEPLOY_KEY="${DEPLOY_KEY:-$HOME/.ssh/id_rsa}"

# StrictHostKeyChecking=yes requires the server's host key to already be in
# ~/.ssh/known_hosts. On the very first deploy, run once with:
#   ssh -o StrictHostKeyChecking=accept-new <DEPLOY_HOST> true
# to register the key, then all subsequent deploys use strict checking.
SSH_OPTS="-i $DEPLOY_KEY -o StrictHostKeyChecking=yes"

rsync -az --delete -e "ssh $SSH_OPTS" \
  --exclude='.env' \
  --exclude='mtg/config.toml' \
  --exclude='xray/config.json' \
  --exclude='ipsec/' \
  --exclude='web/index.html' \
  --exclude='web/.htpasswd' \
  ./ "${DEPLOY_HOST}:${DEPLOY_REMOTE_DIR}/"

ssh $SSH_OPTS "$DEPLOY_HOST" "chmod +x ${DEPLOY_REMOTE_DIR}/*.sh"

echo "Synced → ${DEPLOY_HOST}:${DEPLOY_REMOTE_DIR}"

echo "Re-rendering configs on server..."
ssh $SSH_OPTS "$DEPLOY_HOST" "cd ${DEPLOY_REMOTE_DIR} && ./render-xray-config.sh && ./render-credentials-page.sh"

echo "Restarting containers..."
ssh $SSH_OPTS "$DEPLOY_HOST" "cd ${DEPLOY_REMOTE_DIR} && docker compose up -d --force-recreate"

echo "Deploy complete."
