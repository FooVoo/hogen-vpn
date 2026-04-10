#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

# Overridable via environment variables or .deploy.env file.
# See .deploy.env.example for reference.
[[ -f "$(dirname "$0")/.deploy.env" ]] && source "$(dirname "$0")/.deploy.env"
DEPLOY_HOST="${DEPLOY_HOST:-root@gate.foovoo.dev}"
DEPLOY_REMOTE_DIR="${DEPLOY_REMOTE_DIR:-/opt/vpn}"
DEPLOY_KEY="${DEPLOY_KEY:-$HOME/.ssh/id_rsa}"

# StrictHostKeyChecking=yes requires the server's host key to already be in
# ~/.ssh/known_hosts. On the very first deploy, run once with:
#   ssh -o StrictHostKeyChecking=accept-new <DEPLOY_HOST> true
# to register the key, then all subsequent deploys use strict checking.
SSH_OPTS=(-i "$DEPLOY_KEY" -o StrictHostKeyChecking=yes)

rsync -az --delete -e "ssh ${SSH_OPTS[*]}" \
  --exclude='.env' \
  --exclude='mtg/' \
  --exclude='telemt/' \
  --exclude='xray/' \
  --exclude='ipsec/' \
  --exclude='wireguard/' \
  --exclude='web/index.html' \
  --exclude='web/.htpasswd' \
  --exclude='*.md' \
  ./ "${DEPLOY_HOST}:${DEPLOY_REMOTE_DIR}/"

ssh "${SSH_OPTS[@]}" "$DEPLOY_HOST" "chmod +x ${DEPLOY_REMOTE_DIR}/*.sh"

log_ok "Synced → ${DEPLOY_HOST}:${DEPLOY_REMOTE_DIR}"

# Only re-render and restart when .env already exists on the remote.
# On a fresh server (first deploy) .env is absent — print setup instructions instead.
if ssh "${SSH_OPTS[@]}" "$DEPLOY_HOST" "test -f ${DEPLOY_REMOTE_DIR}/.env" 2>/dev/null; then
  log_info "Re-rendering configs on server..."
  ssh "${SSH_OPTS[@]}" "$DEPLOY_HOST" \
    "cd ${DEPLOY_REMOTE_DIR} && grep -q '^XRAY_UUID=' .env 2>/dev/null && ./render-xray-config.sh || true"
  ssh "${SSH_OPTS[@]}" "$DEPLOY_HOST" \
    "cd ${DEPLOY_REMOTE_DIR} && ./render-credentials-page.sh && sudo ./render-nginx-vhost.sh"

  log_info "Restarting containers..."
  ssh "${SSH_OPTS[@]}" "$DEPLOY_HOST" "cd ${DEPLOY_REMOTE_DIR} && docker compose up -d --force-recreate"

  log_ok "Deploy complete."
else
  log_warn "No .env found on remote — skipping render and container restart."
  log_info "SSH to the server and run initial setup:"
  log_info "  ssh ${DEPLOY_HOST} 'cd ${DEPLOY_REMOTE_DIR} && ./generate-secrets.sh <SERVER_IP> [--services=LIST]'"
  log_info "  ssh ${DEPLOY_HOST} 'cd ${DEPLOY_REMOTE_DIR} && sudo ./setup-nginx.sh'"
  log_ok "Scripts ready — waiting for initial setup on ${DEPLOY_HOST}."
fi
