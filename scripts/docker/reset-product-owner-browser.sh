#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_ARGS=(-f "$ROOT_DIR/docker-compose.yml")
EXTRA_COMPOSE_FILE="$ROOT_DIR/docker-compose.extra.yml"
DOTENV_PATH="$ROOT_DIR/.env"
DRY_RUN=0

if [[ -f "$EXTRA_COMPOSE_FILE" ]]; then
  COMPOSE_ARGS+=(-f "$EXTRA_COMPOSE_FILE")
fi

usage() {
  cat <<'EOF'
Usage: reset-product-owner-browser.sh [--dry-run]

Stops the Dockerized OpenClaw gateway, removes the persisted OpenClaw browser
profile, and starts the gateway again.

Use this when the browser runtime keeps timing out or gets stuck in a bad state.
EOF
}

read_dotenv_value() {
  local file="$1"
  local key="$2"
  local line=""
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" == "$key="* ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <"$file"
}

compose_cli() {
  docker compose "${COMPOSE_ARGS[@]}" "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-}"
if [[ -z "$OPENCLAW_CONFIG_DIR" ]]; then
  OPENCLAW_CONFIG_DIR="$(read_dotenv_value "$DOTENV_PATH" "OPENCLAW_CONFIG_DIR")"
fi
OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"

BROWSER_PROFILE_DIR="$OPENCLAW_CONFIG_DIR/browser/openclaw"

echo "Gateway service: openclaw-gateway"
echo "Browser profile dir: $BROWSER_PROFILE_DIR"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] docker compose stop openclaw-gateway"
  echo "[dry-run] rm -rf $BROWSER_PROFILE_DIR"
  echo "[dry-run] docker compose up -d openclaw-gateway"
  exit 0
fi

compose_cli stop openclaw-gateway
rm -rf "$BROWSER_PROFILE_DIR"
compose_cli up -d openclaw-gateway

echo "OpenClaw browser profile reset complete."
