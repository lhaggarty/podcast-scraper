#!/usr/bin/env bash
# server-pipeline.sh — podcast server pipeline helper
# Modes:
#   cache   -> push excerpt payloads to server cache only (no summary send)
#   trigger -> trigger server summary from cached excerpts
#
# Usage:
#   ./server-pipeline.sh cache all
#   ./server-pipeline.sh cache macro
#   ./server-pipeline.sh trigger all
#   ./server-pipeline.sh trigger macro

set -euo pipefail

SCRAPER_DIR="/Users/leonhaggarty/code/podcast-scraper"
FEEDS_FILE="$SCRAPER_DIR/feeds.json"
MODE="${1:-trigger}"
TARGET="${2:-all}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-168}"
SEND_TO_TELEGRAM="${SEND_TO_TELEGRAM:-true}"
DRY_RUN="${DRY_RUN:-false}"

case "$SEND_TO_TELEGRAM" in
  1|true|TRUE|yes|YES) SEND_TO_TELEGRAM="true" ;;
  *) SEND_TO_TELEGRAM="false" ;;
esac
case "$DRY_RUN" in
  1|true|TRUE|yes|YES) DRY_RUN="true" ;;
  *) DRY_RUN="false" ;;
esac

if [[ "$MODE" != "cache" && "$MODE" != "trigger" ]]; then
  echo "Invalid mode: $MODE (expected: cache|trigger)"
  exit 1
fi

cd "$SCRAPER_DIR"

if [[ -f "$SCRAPER_DIR/venv/bin/activate" ]]; then
  source "$SCRAPER_DIR/venv/bin/activate"
fi

if [[ -f "$SCRAPER_DIR/.env" ]]; then
  set -a
  source "$SCRAPER_DIR/.env"
  set +a
fi

WEBHOOK_CRON_URL="${WEBHOOK_CRON_URL:-}"
WEBHOOK_CRON_API_TOKEN="${WEBHOOK_CRON_API_TOKEN:-}"
if [[ -z "$WEBHOOK_CRON_URL" || -z "$WEBHOOK_CRON_API_TOKEN" ]]; then
  echo "Missing WEBHOOK_CRON_URL or WEBHOOK_CRON_API_TOKEN"
  exit 1
fi

resolve_groups() {
  if [[ "$TARGET" != "all" ]]; then
    echo "$TARGET"
    return 0
  fi

  python3 - <<'PY' "$FEEDS_FILE"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
for k in data.keys():
    print(k)
PY
}

post_cache_group() {
  local group="$1"
  local excerpt_file
  local body_file
  local response

  excerpt_file="$(mktemp /tmp/podcast-excerpt.XXXXXX.json)"
  body_file="$(mktemp /tmp/podcast-cache-body.XXXXXX.json)"

  python3 src/cli.py export-json -g "$group" -l "$LOOKBACK_HOURS" \
    --max-episodes-total 40 --max-episodes-per-feed 4 --excerpt-chars 10000 \
    > "$excerpt_file"

  python3 - "$group" "$excerpt_file" "$body_file" <<'PY'
import json, sys
group = sys.argv[1]
excerpt_path = sys.argv[2]
body_path = sys.argv[3]
with open(excerpt_path, "r", encoding="utf-8") as f:
    payload = json.load(f)
payload["group"] = group
payload["cacheOnly"] = True
payload["sendToTelegram"] = False
payload["dryRun"] = True
payload["includeSummaryText"] = False
with open(body_path, "w", encoding="utf-8") as f:
    json.dump(payload, f)
PY

  response="$(
    curl -sS -m 120 \
      -X POST "${WEBHOOK_CRON_URL%/}/api/pipelines/podcast-summary" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $WEBHOOK_CRON_API_TOKEN" \
      --data-binary "@$body_file"
  )"

  rm -f "$excerpt_file" "$body_file"

  python3 - "$group" "$response" <<'PY'
import json, sys
group = sys.argv[1]
raw = sys.argv[2]
try:
    data = json.loads(raw)
except Exception:
    print(f"[cache] {group}: invalid response")
    sys.exit(1)
if not data.get("ok"):
    print(f"[cache] {group}: failed ({data.get('error', 'unknown error')})")
    sys.exit(1)
print(f"[cache] {group}: {data.get('status', 'ok')} (cachedCount={data.get('cachedCount', 0)})")
PY
}

trigger_group() {
  local group="$1"
  local body_file
  local response

  body_file="$(mktemp /tmp/podcast-trigger-body.XXXXXX.json)"
  python3 - "$group" "$LOOKBACK_HOURS" "$SEND_TO_TELEGRAM" "$DRY_RUN" "$body_file" <<'PY'
import json, sys
group = sys.argv[1]
lookback = int(sys.argv[2])
send_to_telegram = str(sys.argv[3]).lower() == "true"
dry_run = str(sys.argv[4]).lower() == "true"
body_path = sys.argv[5]
payload = {
    "group": group,
    "lookbackHours": lookback,
    "maxEpisodesTotal": 40,
    "maxEpisodesPerFeed": 4,
    "sendToTelegram": send_to_telegram,
    "dryRun": dry_run,
    "includeSummaryText": False,
}
with open(body_path, "w", encoding="utf-8") as f:
    json.dump(payload, f)
PY

  response="$(
    curl -sS -m 120 \
      -X POST "${WEBHOOK_CRON_URL%/}/api/pipelines/podcast-summary" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $WEBHOOK_CRON_API_TOKEN" \
      --data-binary "@$body_file"
  )"
  rm -f "$body_file"

  python3 - "$group" "$response" <<'PY'
import json, sys
group = sys.argv[1]
raw = sys.argv[2]
try:
    data = json.loads(raw)
except Exception:
    print(f"[trigger] {group}: invalid response")
    sys.exit(1)
if not data.get("ok"):
    print(f"[trigger] {group}: failed ({data.get('error', 'unknown error')})")
    sys.exit(1)
already = bool(data.get("alreadyProcessed"))
status = data.get("status", "ok")
if already:
    print(f"[trigger] {group}: already processed ({status})")
else:
    print(f"[trigger] {group}: {status}")
PY
}

groups="$(resolve_groups || true)"
if [[ -z "$groups" ]]; then
  echo "No groups resolved for target: $TARGET"
  exit 1
fi

fail_count=0
for group in $groups; do
  if [[ "$MODE" == "cache" ]]; then
    post_cache_group "$group" || fail_count=$((fail_count + 1))
  else
    trigger_group "$group" || fail_count=$((fail_count + 1))
  fi
done

if [[ "$fail_count" -gt 0 ]]; then
  echo "Completed with failures: $fail_count"
  exit 1
fi

echo "Completed: mode=$MODE target=$TARGET"
