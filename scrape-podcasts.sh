#!/usr/bin/env bash
# scrape-podcasts.sh — Scheduled podcast scraper + digest pipeline
# Called by Open Claw cron or manually.
#
# Usage:
#   ./scrape-podcasts.sh                  # default group: macro
#   ./scrape-podcasts.sh macro            # run a specific feed group
#   ./scrape-podcasts.sh all              # scrape once, then send separate digests per group
#
# Crontab example (every Sunday at 9am):
#   0 9 * * 0 /Users/leonhaggarty/code/podcast-scraper/scrape-podcasts.sh >> /Users/leonhaggarty/code/podcast-scraper/scrape.log 2>&1

set -euo pipefail

SCRAPER_DIR="/Users/leonhaggarty/code/podcast-scraper"
LOG_FILE="$SCRAPER_DIR/scrape.log"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

# Always append output to the log file
exec >> "$LOG_FILE" 2>&1

# Mode / group argument (default: macro)
MODE="${1:-macro}"

# Optional: delegate summarization + Telegram digest delivery to webhook-cron-serverless.
# If this succeeds, we skip the local summarization + Telegram send (to avoid duplicates).

OPENCLAW="/Users/leonhaggarty/.nvm/versions/node/v24.13.0/bin/openclaw"
TG_TARGET="6113620394"
AGENT_BIN="$HOME/.local/bin/agent"
FEEDS_FILE="$SCRAPER_DIR/feeds.json"

echo "$LOG_PREFIX Starting podcast scrape (mode: $MODE)"

cd "$SCRAPER_DIR"

# Activate venv if it exists
if [[ -f "$SCRAPER_DIR/venv/bin/activate" ]]; then
  source "$SCRAPER_DIR/venv/bin/activate"
fi

# Load optional local .env (gitignored) so cron can run without
# embedding tokens in job definitions.
if [[ -f "$SCRAPER_DIR/.env" ]]; then
  set -a
  source "$SCRAPER_DIR/.env"
  set +a
fi

WEBHOOK_CRON_URL="${WEBHOOK_CRON_URL:-}"
WEBHOOK_CRON_API_TOKEN="${WEBHOOK_CRON_API_TOKEN:-}"

PIPELINE_DRY_RUN="false"
case "${PODCAST_PIPELINE_DRY_RUN:-}" in
  1|true|TRUE|yes|YES) PIPELINE_DRY_RUN="true" ;;
esac

get_groups() {
  if [[ "$MODE" != "all" ]]; then
    echo "$MODE"
    return 0
  fi

  # Print one group per line.
  python3 - <<'PY' "$FEEDS_FILE" 2>/dev/null
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
for k in data.keys():
    print(k)
PY
}

# --- Step 1: Scrape feeds (fetch + transcribe) ---
echo "$LOG_PREFIX [scrape] Scraping podcast feeds..."
set +e
if [[ "$MODE" == "all" ]]; then
  SCRAPE_OUTPUT=$(python3 src/cli.py scrape -n 1 2>&1)
else
  SCRAPE_OUTPUT=$(python3 src/cli.py scrape -g "$MODE" -n 1 2>&1)
fi
SCRAPE_EXIT=$?
set -e
echo "$SCRAPE_OUTPUT"

if [[ "$SCRAPE_EXIT" -ne 0 ]]; then
  echo "$LOG_PREFIX Scrape failed (exit: $SCRAPE_EXIT)"
fi

PODCAST_GROUPS="$(get_groups || true)"
if [[ -z "$PODCAST_GROUPS" ]]; then
  echo "$LOG_PREFIX [error] No groups resolved (mode: $MODE)"
  exit 1
fi

run_group() {
  local group="$1"

  echo "$LOG_PREFIX ===== Digest group: $group ====="

  local export_file="/tmp/podcasts_${group}_export.txt"
  local excerpt_json_file="/tmp/podcasts_${group}_excerpt.json"
  local summary_file="/tmp/podcasts_${group}_summary.txt"

  rm -f "$summary_file" || true

  # Export full transcripts to a file (useful for manual debugging and fallback).
  echo "$LOG_PREFIX [export] Exporting transcripts (group: $group)..."
  set +e
  python3 src/cli.py export -g "$group" -l 168 -o "$export_file" 2>&1
  local export_exit=$?
  set -e
  if [[ "$export_exit" -ne 0 ]]; then
    echo "$LOG_PREFIX [export] Export failed (exit: $export_exit) — continuing"
  fi

  # Build size-bounded excerpt payload for summarization (JSON-only on stdout).
  local excerpt_json=""
  excerpt_json=$(python3 src/cli.py export-json -g "$group" -l 168 \
    --max-episodes-total 40 --max-episodes-per-feed 4 --excerpt-chars 10000 2>/dev/null) || true

  if [[ -n "$excerpt_json" ]]; then
    printf "%s\n" "$excerpt_json" > "$excerpt_json_file"
  else
    rm -f "$excerpt_json_file" || true
  fi

  local episode_count=0
  episode_count=$(
    python3 - <<'PY' "$excerpt_json_file" 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    print(len(data.get("episodes") or []))
except Exception:
    print(0)
PY
  ) || echo 0

  if [[ "$episode_count" -eq 0 ]]; then
    echo "$LOG_PREFIX [export-json] No episodes to summarize for group: $group"
    return 0
  fi

  local server_ok="false"
  local summary_ok="false"
  local agent_fail_reason=""
  local send_to_telegram="true"
  local dry_run="false"

  if [[ "$PIPELINE_DRY_RUN" == "true" ]]; then
    send_to_telegram="false"
    dry_run="true"
  fi

  # --- Prefer server-side summary ---
  if [[ -n "$WEBHOOK_CRON_URL" && -n "$WEBHOOK_CRON_API_TOKEN" && -f "$excerpt_json_file" ]]; then
    echo "$LOG_PREFIX [server-summary] Triggering server pipeline (group: $group)..."

    local server_body=""
    server_body=$(
      python3 - "$excerpt_json_file" "$send_to_telegram" "$dry_run" 2>/dev/null <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
data["sendToTelegram"] = (str(sys.argv[2]).lower() == "true")
data["dryRun"] = (str(sys.argv[3]).lower() == "true")
data["includeSummaryText"] = True
print(json.dumps(data))
PY
    ) || true

    if [[ -n "$server_body" ]]; then
      local server_endpoint="${WEBHOOK_CRON_URL%/}/api/pipelines/podcast-summary"
      local server_response=""
      server_response=$(
        curl -sS -m 120 \
          -X POST "$server_endpoint" \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $WEBHOOK_CRON_API_TOKEN" \
          -d "$server_body"
      ) || true

      if [[ -n "$server_response" ]]; then
        echo "$server_response"

        server_ok="$(
          python3 - "$server_response" 2>/dev/null <<'PY' || echo "false"
import json, sys
try:
    data = json.loads(sys.argv[1])
    print("true" if data.get("ok") else "false")
except Exception:
    print("false")
PY
        )"

        if [[ "$server_ok" == "true" ]]; then
          local server_summary_text=""
          server_summary_text="$(
            python3 - "$server_response" 2>/dev/null <<'PY' || true
import json, sys
try:
    data = json.loads(sys.argv[1])
    text = data.get("summaryText")
    if isinstance(text, str) and text.strip():
        print(text.strip())
except Exception:
    pass
PY
          )"

          if [[ -n "$server_summary_text" ]]; then
            printf "%s\n" "$server_summary_text" > "$summary_file" || true
            summary_ok="true"
          fi

          echo "$LOG_PREFIX [server-summary] Success (Telegram sent server-side)"
          echo "SUMMARY_SOURCE: server"
          echo "SUMMARY_FILE: $summary_file"
        else
          echo "$LOG_PREFIX [server-summary] Server pipeline failed/unavailable; falling back to local summarization."
        fi
      fi
    fi
  fi

  # --- Local summarization fallback (Cursor Agent CLI + Open Claw fallback) ---
  if [[ "$server_ok" != "true" ]]; then
    echo "$LOG_PREFIX [local-summary] Summarizing excerpts via Cursor Agent CLI (group: $group)..."

    local prompt_file=""
    prompt_file=$(mktemp /tmp/podcast-summary-prompt.XXXXXX)
    cat > "$prompt_file" <<PROMPT_EOF
Read the podcast transcript excerpts below (JSON) and produce a concise briefing (300-500 words).

Output format (exact headings):
THEMATIC OVERVIEW
<1-2 short paragraphs of cross-show themes and key takeaways>

PER-PODCAST HIGHLIGHTS
<One short paragraph per podcast/feed, 1-3 sentences each>

Do NOT include any preamble like "Here is the summary".
Just output the briefing text directly.

--- EXCERPTS_JSON START ---
$(cat "$excerpt_json_file")
--- EXCERPTS_JSON END ---
PROMPT_EOF

    if [[ -x "$AGENT_BIN" ]]; then
      local expect_script=""
      expect_script=$(mktemp /tmp/podcast-summary-expect.XXXXXX)
      cat > "$expect_script" <<'EXPECT_EOF'
set timeout 120
set prompt_file [lindex $argv 0]
set agent_bin [lindex $argv 1]

spawn -noecho sh -c "cat $prompt_file | env TERM=xterm-256color $agent_bin -p --model gemini-3-pro"
expect {
    timeout { puts "AGENT_TIMEOUT"; exit 1 }
    eof {}
}
lassign [wait] pid spawnid os_error exit_code
exit $exit_code
EXPECT_EOF

      set +e
      expect "$expect_script" "$prompt_file" "$AGENT_BIN" > "$summary_file" 2>/dev/null
      local agent_exit=$?
      set -e
      rm -f "$expect_script" "$prompt_file"

      if [[ "$agent_exit" -eq 0 && -s "$summary_file" ]]; then
        echo "$LOG_PREFIX [summary] Cursor Agent CLI succeeded"
        summary_ok="true"
      else
        agent_fail_reason="exit code $agent_exit"
        [[ "$agent_exit" -eq 1 ]] && grep -q "AGENT_TIMEOUT" "$summary_file" 2>/dev/null && agent_fail_reason="timed out after 120s"
        echo "$LOG_PREFIX [summary] Cursor Agent CLI failed ($agent_fail_reason)"
        rm -f "$summary_file"
      fi
    else
      agent_fail_reason="agent binary not found at $AGENT_BIN"
      echo "$LOG_PREFIX [summary] $agent_fail_reason"
      rm -f "$prompt_file"
    fi

    # --- Send results (local path only; server path already delivered) ---
    if [[ "$summary_ok" == "true" && -s "$summary_file" ]]; then
      local summary_content=""
      summary_content=$(head -c 4000 "$summary_file")
        if [[ "$PIPELINE_DRY_RUN" != "true" && -x "$OPENCLAW" ]]; then
        "$OPENCLAW" message send \
          --channel telegram \
          --target "$TG_TARGET" \
          -m "Podcast Digest ($group):\n\n$summary_content" \
          2>/dev/null || true
        echo "$LOG_PREFIX [telegram] Summary sent via Cursor Agent"
      fi
      echo "SUMMARY_SOURCE: cursor-agent"
      echo "SUMMARY_FILE: $summary_file"
    else
      # Cursor Agent failed — notify user, signal Open Claw fallback.
      if [[ "$PIPELINE_DRY_RUN" != "true" && -x "$OPENCLAW" ]]; then
        "$OPENCLAW" message send \
          --channel telegram \
          --target "$TG_TARGET" \
          -m "[Podcast pipeline] Summarization failed (${agent_fail_reason:-unknown}). Falling back to Open Claw AI. Excerpts are ready." \
          2>/dev/null || true
      fi
      echo "EXCERPT_JSON_FILE: $excerpt_json_file"
      echo "AGENT_FAIL_REASON: ${agent_fail_reason:-unknown}"
      echo "SUMMARY_SOURCE: needs-fallback"
    fi
  fi

  # --- Store summary in MongoDB (if one was generated) ---
  if [[ -s "$summary_file" ]]; then
    local twitter_scraper_dir="/Users/leonhaggarty/code/twitter-scraper"
    if [[ -f "$twitter_scraper_dir/src/store-summary.ts" ]]; then
      echo "$LOG_PREFIX [mongo] Storing summary in MongoDB..."
      (
        cd "$twitter_scraper_dir" \
        && bun run src/store-summary.ts -- \
          --group "$group" --source podcast \
          --summary-file "$summary_file" \
          -m "${MONGO_URI:-${ATLAS_URI:-}}" 2>&1
      ) || echo "$LOG_PREFIX [mongo] Summary storage failed (non-fatal)"
    fi
  fi

  # --- Audio Digest: generate audio version ---
  local audio_digest_dir="/Users/leonhaggarty/code/audio-digest"
  if [[ -d "$audio_digest_dir/venv" && -s "$summary_file" ]]; then
    echo "$LOG_PREFIX [audio] Generating audio from AI summary..."
    (
      cd "$audio_digest_dir" \
      && source venv/bin/activate \
      && python -m engine.cli generate "$summary_file" --source podcast --group "$group" 2>&1
    ) || echo "$LOG_PREFIX [audio] Audio generation failed (non-fatal)"
  fi
}

for group in $PODCAST_GROUPS; do
  run_group "$group" || echo "$LOG_PREFIX [warn] Group pipeline failed (non-fatal): $group"
done

if [[ "$PIPELINE_DRY_RUN" != "true" && "$SCRAPE_EXIT" -ne 0 ]] && [[ -x "$OPENCLAW" ]]; then
  "$OPENCLAW" message send \
    --channel telegram \
    --target "$TG_TARGET" \
    -m "Podcast scrape FAILED (mode: $MODE, exit $SCRAPE_EXIT). Check ~/code/podcast-scraper/scrape.log" \
    2>/dev/null || true
fi

echo "$LOG_PREFIX Finished (exit: $SCRAPE_EXIT)"
exit "$SCRAPE_EXIT"
