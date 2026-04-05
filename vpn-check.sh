#!/usr/bin/env bash
# vpn-check.sh — fetch VPN health-check status via SSH.
# The /check endpoint is NOT public; it listens only on 127.0.0.1:9000.
# Run this script locally — it opens an SSH connection and curls the server.
#
# Usage:
#   ./vpn-check.sh user@your-server            # pretty HTML (opens in $PAGER)
#   ./vpn-check.sh user@your-server --json     # raw JSON
#
# Requirements: ssh, curl available on the remote host.
set -euo pipefail

TARGET="${1:-}"
MODE="${2:-}"

if [[ -z "$TARGET" ]]; then
  echo "Usage: $0 user@host [--json]"
  exit 1
fi

if [[ "$MODE" == "--json" ]]; then
  ssh -T "$TARGET" -- curl -sf http://127.0.0.1:9000/check/status.json
else
  ssh -T "$TARGET" -- curl -sf http://127.0.0.1:9000/check/
fi
