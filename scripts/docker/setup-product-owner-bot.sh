#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage: setup-product-owner-bot.sh [cron-sync-options]

Bootstraps the Dockerized OpenClaw gateway, then seeds or updates the Product
Owner bot cron jobs.

Cron sync options are passed through to sync-product-owner-crons.sh, for example:
  --community-monitor-every 2m
  --trello-done-docs-every 30m
  --dry-run
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

bash "$ROOT_DIR/docker-setup.sh"
bash "$ROOT_DIR/scripts/docker/sync-product-owner-crons.sh" "$@"
