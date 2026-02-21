#!/usr/bin/env bash
# audio-followup.sh -- build audio episodes from latest podcast summaries
# Strategy per group:
# 1) Try server summary API (includeSummaryText, no Telegram send)
# 2) If unavailable, summarize locally via Ollama from export-json excerpts
# 3) Generate audio with audio-digest

set -euo pipefail

SCRAPER_DIR="/Users/leonhaggarty/code/podcast-scraper"
FEEDS_FILE="$SCRAPER_DIR/feeds.json"
LOG_FILE="$SCRAPER_DIR/audio-followup.log"
TARGET="${1:-all}"

LOOKBACK_HOURS="${LOOKBACK_HOURS:-168}"
WEBHOOK_CRON_URL_DEFAULT=""
WEBHOOK_CRON_API_TOKEN_DEFAULT=""
OLLAMA_WRAPPER="${OLLAMA_WRAPPER:-/Users/leonhaggarty/code/text-summary-tool/ollama-fallback.py}"
AUDIO_DIGEST_DIR="/Users/leonhaggarty/code/audio-digest"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

exec >> "$LOG_FILE" 2>&1
cd "$SCRAPER_DIR"

if [[ -f "$SCRAPER_DIR/venv/bin/activate" ]]; then
  source "$SCRAPER_DIR/venv/bin/activate"
fi

if [[ -f "$SCRAPER_DIR/.env" ]]; then
  set -a
  source "$SCRAPER_DIR/.env"
  set +a
fi

WEBHOOK_CRON_URL="${WEBHOOK_CRON_URL:-$WEBHOOK_CRON_URL_DEFAULT}"
WEBHOOK_CRON_API_TOKEN="${WEBHOOK_CRON_API_TOKEN:-$WEBHOOK_CRON_API_TOKEN_DEFAULT}"

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

try_server_summary() {
  local group="$1"
  local summary_file="$2"
  local body_file
  local response
  local parse_result

  if [[ -z "$WEBHOOK_CRON_URL" || -z "$WEBHOOK_CRON_API_TOKEN" ]]; then
    log "[server] Missing WEBHOOK vars; skipping server attempt."
    return 1
  fi

  body_file="$(mktemp /tmp/podcast-audio-body.XXXXXX.json)"
  python3 - "$group" "$LOOKBACK_HOURS" "$body_file" <<'PY'
import json, sys
group = sys.argv[1]
lookback = int(sys.argv[2])
body_path = sys.argv[3]
payload = {
    "group": group,
    "lookbackHours": lookback,
    "maxEpisodesTotal": 40,
    "maxEpisodesPerFeed": 4,
    "sendToTelegram": False,
    "dryRun": True,
    "includeSummaryText": True,
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
  )" || true
  rm -f "$body_file"

  if [[ -z "$response" ]]; then
    log "[server] Empty response for group=$group"
    return 1
  fi

  parse_result="$(
    python3 - "$response" "$summary_file" <<'PY'
import json, sys
raw = sys.argv[1]
out_path = sys.argv[2]
try:
    data = json.loads(raw)
except Exception:
    print("parse_error")
    raise SystemExit(1)
if not data.get("ok"):
    print("not_ok")
    raise SystemExit(1)
text = data.get("summaryText")
if isinstance(text, str) and text.strip():
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(text.strip())
        f.write("\n")
    print("ok_with_summary")
else:
    print("ok_no_summary")
PY
  )" || true

  if [[ "$parse_result" == "ok_with_summary" && -s "$summary_file" ]]; then
    log "[server] Summary ready for group=$group"
    return 0
  fi

  log "[server] No summary text available for group=$group (result=$parse_result)"
  return 1
}

try_ollama_summary() {
  local group="$1"
  local summary_file="$2"
  local excerpt_file
  local prompt_file
  local episode_count

  if [[ ! -f "$OLLAMA_WRAPPER" ]]; then
    log "[ollama] Wrapper missing at $OLLAMA_WRAPPER"
    return 1
  fi

  excerpt_file="$(mktemp /tmp/podcast-audio-excerpt.XXXXXX.json)"
  prompt_file="$(mktemp /tmp/podcast-audio-prompt.XXXXXX.txt)"

  if ! python3 src/cli.py export-json -g "$group" -l "$LOOKBACK_HOURS" \
    --max-episodes-total 24 --max-episodes-per-feed 3 --excerpt-chars 5000 \
    > "$excerpt_file"; then
    rm -f "$excerpt_file" "$prompt_file"
    log "[ollama] Failed to export excerpts for group=$group"
    return 1
  fi

  episode_count="$(
    python3 - "$excerpt_file" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    print(len(data.get("episodes") or []))
except Exception:
    print(0)
PY
  )"

  if [[ "$episode_count" -eq 0 ]]; then
    rm -f "$excerpt_file" "$prompt_file"
    log "[ollama] No podcast episodes for group=$group; skipping."
    return 2
  fi

  cat > "$prompt_file" <<PROMPT_EOF
Read the podcast transcript excerpt payload below and produce a concise market briefing (400-600 words).

Use exactly two sections:
1) THEMATIC OVERVIEW
2) PER-SHOW HIGHLIGHTS

No preamble. Output only briefing text.

--- EXCERPT PAYLOAD START ---
$(cat "$excerpt_file")
--- EXCERPT PAYLOAD END ---
PROMPT_EOF

  if ! python3 "$OLLAMA_WRAPPER" --prompt-file "$prompt_file" --output-file "$summary_file" >/dev/null 2>&1; then
    rm -f "$excerpt_file" "$prompt_file"
    log "[ollama] Summarization failed for group=$group"
    return 1
  fi

  rm -f "$excerpt_file" "$prompt_file"
  if [[ ! -s "$summary_file" ]]; then
    log "[ollama] Empty summary output for group=$group"
    return 1
  fi

  log "[ollama] Summary ready for group=$group"
  return 0
}

generate_audio() {
  local group="$1"
  local summary_file="$2"

  if [[ ! -f "$AUDIO_DIGEST_DIR/venv/bin/activate" ]]; then
    log "[audio] audio-digest venv missing."
    return 1
  fi

  (
    cd "$AUDIO_DIGEST_DIR" \
      && source venv/bin/activate \
      && python -m engine.cli generate "$summary_file" --source podcast --group "$group"
  ) || return 1

  return 0
}

groups="$(resolve_groups || true)"
if [[ -z "$groups" ]]; then
  log "[error] No groups resolved for target: $TARGET"
  exit 1
fi

log "Starting podcast audio follow-up (target=$TARGET)"
fail_count=0

for group in $groups; do
  summary_file="/tmp/podcast_${group}_summary.txt"
  rm -f "$summary_file" || true
  summary_source=""

  if try_server_summary "$group" "$summary_file"; then
    summary_source="server"
  else
    if try_ollama_summary "$group" "$summary_file"; then
      summary_source="ollama"
    else
      ollama_exit=$?
      if [[ "$ollama_exit" -eq 2 ]]; then
        log "[group=$group] No summary content available; skipping audio."
        echo "SUMMARY_SOURCE: needs-fallback"
        echo "AUDIO_STATUS: skipped-no-content"
        continue
      fi
      log "[group=$group] Server + Ollama summary failed."
      echo "SUMMARY_SOURCE: needs-fallback"
      echo "AUDIO_STATUS: failed"
      fail_count=$((fail_count + 1))
      continue
    fi
  fi

  if generate_audio "$group" "$summary_file"; then
    echo "SUMMARY_SOURCE: $summary_source"
    echo "AUDIO_STATUS: generated"
  else
    log "[group=$group] Audio generation failed."
    echo "SUMMARY_SOURCE: $summary_source"
    echo "AUDIO_STATUS: failed"
    fail_count=$((fail_count + 1))
  fi
done

if [[ "$fail_count" -gt 0 ]]; then
  log "Completed with failures: $fail_count"
  exit 1
fi

log "Completed successfully."
exit 0
