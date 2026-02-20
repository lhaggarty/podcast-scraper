#!/usr/bin/env bash
# server-pipeline.sh — podcast server pipeline helper
# Modes:
#   cache   -> push excerpt payloads to server cache only (no summary send)
#   trigger -> trigger server summary from cached excerpts (Ollama fallback on failure)
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
OLLAMA_WRAPPER="${OLLAMA_WRAPPER:-/Users/leonhaggarty/code/text-summary-tool/ollama-fallback.py}"
OPENCLAW_BIN="${OPENCLAW_BIN:-/Users/leonhaggarty/.nvm/versions/node/v24.13.0/bin/openclaw}"
TELEGRAM_TARGET="${TELEGRAM_TARGET:-6113620394}"

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

trigger_ollama_fallback() {
  local group="$1"
  local excerpt_file
  local prompt_file
  local summary_file
  local summary_content

  if [[ ! -f "$OLLAMA_WRAPPER" ]]; then
    echo "[trigger] $group: ollama wrapper not found at $OLLAMA_WRAPPER"
    return 1
  fi

  excerpt_file="$(mktemp /tmp/podcast-ollama-excerpt.XXXXXX.json)"
  prompt_file="$(mktemp /tmp/podcast-ollama-prompt.XXXXXX.txt)"
  summary_file="/tmp/podcast_${group}_summary.txt"

  if ! python3 src/cli.py export-json -g "$group" -l "$LOOKBACK_HOURS" \
    --max-episodes-total 24 --max-episodes-per-feed 3 --excerpt-chars 5000 \
    > "$excerpt_file"; then
    echo "[trigger] $group: failed to build local excerpt payload for Ollama fallback"
    rm -f "$excerpt_file" "$prompt_file"
    return 1
  fi

  if [[ ! -s "$excerpt_file" ]]; then
    echo "[trigger] $group: local excerpt payload is empty for Ollama fallback"
    rm -f "$excerpt_file" "$prompt_file"
    return 1
  fi

  cat > "$prompt_file" <<PROMPT_EOF
Read the podcast transcript excerpt payload below and produce a concise market briefing (400-600 words).

Structure the output in two sections:
1. THEMATIC OVERVIEW — summarize the dominant macro/market themes and important events.
2. PER-SHOW HIGHLIGHTS — list each podcast/show with 1-2 sentences of notable insights.

Write in natural prose. Do not include preamble text.

--- EXCERPT PAYLOAD START ---
$(cat "$excerpt_file")
--- EXCERPT PAYLOAD END ---
PROMPT_EOF

  if ! python3 "$OLLAMA_WRAPPER" --prompt-file "$prompt_file" --output-file "$summary_file" 2>&1; then
    echo "[trigger] $group: Ollama fallback summarization failed"
    rm -f "$excerpt_file" "$prompt_file"
    return 1
  fi

  if [[ ! -s "$summary_file" ]]; then
    echo "[trigger] $group: Ollama fallback produced empty summary"
    rm -f "$excerpt_file" "$prompt_file"
    return 1
  fi

  if [[ "$SEND_TO_TELEGRAM" == "true" && "$DRY_RUN" != "true" ]]; then
    if [[ -x "$OPENCLAW_BIN" ]]; then
      summary_content="$(head -c 4000 "$summary_file")"
      "$OPENCLAW_BIN" message send \
        --channel telegram \
        --target "$TELEGRAM_TARGET" \
        -m "Podcast Digest ($group) [Ollama fallback]:

$summary_content" \
        2>/dev/null || true
    else
      echo "[trigger] $group: Open Claw binary not found at $OPENCLAW_BIN (summary not sent)"
    fi
  fi

  echo "[trigger] $group: local Ollama fallback succeeded"
  echo "SUMMARY_FILE: $summary_file"
  echo "SUMMARY_SOURCE: ollama"
  rm -f "$excerpt_file" "$prompt_file"
  return 0
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
      --data-binary "@$body_file" 2>&1
  )" || true
  rm -f "$body_file"

  if python3 - "$group" "$response" <<'PY'
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
print("SUMMARY_SOURCE: server")
PY
  then
    return 0
  fi

  echo "[trigger] $group: server trigger failed; trying local Ollama fallback..."
  if trigger_ollama_fallback "$group"; then
    return 0
  fi

  echo "[trigger] $group: server + Ollama fallback both failed"
  echo "SUMMARY_SOURCE: needs-fallback"
  return 1
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
