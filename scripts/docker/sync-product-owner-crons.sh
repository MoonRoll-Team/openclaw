#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_ARGS=(-f "$ROOT_DIR/docker-compose.yml")
EXTRA_COMPOSE_FILE="$ROOT_DIR/docker-compose.extra.yml"

if [[ -f "$EXTRA_COMPOSE_FILE" ]]; then
  COMPOSE_ARGS+=(-f "$EXTRA_COMPOSE_FILE")
fi

COMMUNITY_MONITOR_NAME="community-monitor"
TRELLO_DONE_DOCS_NAME="trello-done-docs"
COMMUNITY_MONITOR_EVERY="${COMMUNITY_MONITOR_EVERY:-15m}"
TRELLO_DONE_DOCS_EVERY="${TRELLO_DONE_DOCS_EVERY:-30m}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: sync-product-owner-crons.sh [options]

Upsert the Product Owner bot cron jobs through the Dockerized OpenClaw CLI.

Options:
  --community-monitor-every <duration>  Interval for the community monitor job (default: 15m)
  --trello-done-docs-every <duration>   Interval for the Trello docs job (default: 30m)
  --dry-run                             Print planned changes without applying them
  --help                                Show this help

Examples:
  bash scripts/docker/sync-product-owner-crons.sh
  bash scripts/docker/sync-product-owner-crons.sh --community-monitor-every 2m
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing dependency: $1"
  fi
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

read_config_env_value() {
  local file="$1"
  local key="$2"
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$key" <<'PY'
import json
import sys

path, key = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    raise SystemExit(0)

value = cfg.get("env", {}).get(key)
if isinstance(value, str) and value.strip():
    print(value.strip(), end="")
PY
    return 0
  fi
  if command -v node >/dev/null 2>&1; then
    node - "$file" "$key" <<'NODE'
const fs = require("node:fs");
const [file, key] = process.argv.slice(2);
try {
  const cfg = JSON.parse(fs.readFileSync(file, "utf8"));
  const value = cfg?.env?.[key];
  if (typeof value === "string" && value.trim()) {
    process.stdout.write(value.trim());
  }
} catch {
  process.exit(0);
}
NODE
  fi
}

parse_job_id_from_json() {
  local json="$1"
  local name="$2"
  if command -v python3 >/dev/null 2>&1; then
    JSON_PAYLOAD="$json" python3 - "$name" <<'PY'
import json
import os
import sys

name = sys.argv[1]
try:
    payload = json.loads(os.environ["JSON_PAYLOAD"])
except Exception:
    raise SystemExit(1)

for job in payload.get("jobs", []):
    if job.get("name") == name and isinstance(job.get("id"), str):
        print(job["id"], end="")
        break
PY
    return 0
  fi
  if command -v node >/dev/null 2>&1; then
    JSON_PAYLOAD="$json" node - "$name" <<'NODE'
const name = process.argv[2];
try {
  const payload = JSON.parse(process.env.JSON_PAYLOAD ?? "{}");
  const job = Array.isArray(payload?.jobs) ? payload.jobs.find((entry) => entry?.name === name) : null;
  if (job && typeof job.id === "string") {
    process.stdout.write(job.id);
  }
} catch {
  process.exit(1);
}
NODE
    return 0
  fi
  fail "Need either python3 or node to parse cron JSON."
}

compose_cli() {
  docker compose "${COMPOSE_ARGS[@]}" "$@"
}

run_openclaw_cli() {
  compose_cli run --rm --no-deps openclaw-cli "$@"
}

log_action() {
  printf '%s\n' "$*"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --community-monitor-every)
      [[ $# -ge 2 ]] || fail "Missing value for $1"
      COMMUNITY_MONITOR_EVERY="$2"
      shift 2
      ;;
    --trello-done-docs-every)
      [[ $# -ge 2 ]] || fail "Missing value for $1"
      TRELLO_DONE_DOCS_EVERY="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

require_cmd docker
if ! docker compose version >/dev/null 2>&1; then
  fail "Docker Compose is not available."
fi

DOTENV_PATH="$ROOT_DIR/.env"
OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
OPENCLAW_CONFIG_JSON="$OPENCLAW_CONFIG_DIR/openclaw.json"
DISCORD_DEV_CHANNEL_ID="${DISCORD_DEV_CHANNEL_ID:-}"
if [[ -z "$DISCORD_DEV_CHANNEL_ID" ]]; then
  DISCORD_DEV_CHANNEL_ID="$(read_dotenv_value "$DOTENV_PATH" "DISCORD_DEV_CHANNEL_ID")"
fi
if [[ -z "$DISCORD_DEV_CHANNEL_ID" ]]; then
  DISCORD_DEV_CHANNEL_ID="$(read_config_env_value "$OPENCLAW_CONFIG_JSON" "DISCORD_DEV_CHANNEL_ID")"
fi
[[ -n "$DISCORD_DEV_CHANNEL_ID" ]] || fail "DISCORD_DEV_CHANNEL_ID is not set in the environment, .env, or $OPENCLAW_CONFIG_JSON"

COMMUNITY_MONITOR_MESSAGE="$(cat <<'EOF'
You are a community monitor. Do these steps:

STEP 1: Read the last processed message ID to avoid duplicates:
cat /home/node/.openclaw/workspace/last-message-id.txt 2>/dev/null || echo "none"

STEP 2: Read recent messages from #général (public Discord):
openclaw message read --channel discord --target $DISCORD_PUBLIC_CHANNEL_ID --limit 20

STEP 3: Discover and read ticket channels:
curl -s -H "Authorization: Bot $(openclaw config get channels.discord.token 2>/dev/null)" https://discord.com/api/v10/guilds/$DISCORD_PUBLIC_GUILD_ID/channels | node -e "const d=require(\"fs\").readFileSync(\"/dev/stdin\",\"utf8\");const ch=JSON.parse(d).filter(c=>c.parent_id===\"$DISCORD_PUBLIC_TICKET_CATEGORY_ID\");ch.forEach(c=>console.log(c.id,c.name))"

For each ticket channel found:
openclaw message read --channel discord --target <channel_id> --limit 10

STEP 4: Filter messages. ONLY report messages with an Id NEWER than the last processed ID from step 1. IGNORE:
- Messages from FlokiLaPookie (you) or any bot (Ticket Tool, MEE6, etc.)
- Casual chat, memes, greetings, empty messages
- ANY message you have seen before (older than or equal to the last processed ID)

STEP 5: Save the newest message ID you processed:
echo "<newest_message_id>" > /home/node/.openclaw/workspace/last-message-id.txt

STEP 6: For each NEW noteworthy message from a real user, output:

Community Signal
From: [username] in #[channel]
Category: [Bug / Complaint / Feature Request / Support Ticket]

> [verbatim quote]

Context: [brief explanation]

If no NEW noteworthy messages, output exactly: No new community signals.
EOF
)"

TRELLO_DONE_DOCS_MESSAGE="$(cat <<'EOF'
Check for Trello cards recently moved to Done and update documentation.

STEP 1: List cards in Done:
curl -s "https://api.trello.com/1/lists/$TRELLO_LIST_DONE/cards?key=$TRELLO_API_KEY&token=$TRELLO_TOKEN&fields=id,name,desc,dateLastActivity"

STEP 2: Check which cards moved in the last 2 hours (based on dateLastActivity). If none, output "No recently completed cards." and stop.

STEP 3: Check already-processed cards:
cat /home/node/.openclaw/workspace/docs-updated.log 2>/dev/null || echo "none"
Skip any card ID already in this file.

STEP 4: For new cards, read the moonroll-docs repo and update relevant docs:
cd /home/node/moonroll-docs
export GIT_SSH_COMMAND="ssh -F /home/node/.openclaw/ssh/config"
git pull
Then find and update the relevant documentation files based on what the card describes.
git add <files>
git commit -m "docs: <card title>"
git push

STEP 5: Log processed card IDs:
echo "<cardId>" >> /home/node/.openclaw/workspace/docs-updated.log

STEP 6: Output a summary of what you updated. Skip cards that are internal and do not affect user-facing docs.
EOF
)"

if [[ "$DRY_RUN" -eq 0 ]]; then
  compose_cli up -d openclaw-gateway >/dev/null
fi

CRON_LIST_JSON="$(run_openclaw_cli cron list --all --json)"

upsert_job() {
  local job_name="$1"
  local every="$2"
  local message="$3"
  local job_id=""

  job_id="$(parse_job_id_from_json "$CRON_LIST_JSON" "$job_name")"

  if [[ -n "$job_id" ]]; then
    log_action "Updating $job_name ($job_id) to run every $every"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      run_openclaw_cli cron edit "$job_id" \
        --name "$job_name" \
        --enable \
        --session isolated \
        --wake now \
        --every "$every" \
        --message "$message" \
        --announce \
        --channel discord \
        --to "channel:$DISCORD_DEV_CHANNEL_ID" >/dev/null
    fi
    return 0
  fi

  log_action "Creating $job_name to run every $every"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    run_openclaw_cli cron add \
      --name "$job_name" \
      --every "$every" \
      --session isolated \
      --wake now \
      --message "$message" \
      --announce \
      --channel discord \
      --to "channel:$DISCORD_DEV_CHANNEL_ID" >/dev/null
  fi
}

upsert_job "$COMMUNITY_MONITOR_NAME" "$COMMUNITY_MONITOR_EVERY" "$COMMUNITY_MONITOR_MESSAGE"
upsert_job "$TRELLO_DONE_DOCS_NAME" "$TRELLO_DONE_DOCS_EVERY" "$TRELLO_DONE_DOCS_MESSAGE"

log_action "Cron sync complete."
