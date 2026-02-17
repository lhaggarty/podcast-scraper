#!/usr/bin/env bash
# scrape-podcasts.sh — Scheduled podcast scraper + digest pipeline
# Called by crontab or manually.
#
# Usage:
#   ./scrape-podcasts.sh                  # scrape with defaults (all groups)
#   ./scrape-podcasts.sh macro            # scrape a specific feed group
#
# Crontab example (every Sunday at 9am):
#   0 9 * * 0 /Users/leonhaggarty/code/podcast-scraper/scrape-podcasts.sh >> /Users/leonhaggarty/code/podcast-scraper/scrape.log 2>&1

set -euo pipefail

SCRAPER_DIR="/Users/leonhaggarty/code/podcast-scraper"
LOG_FILE="$SCRAPER_DIR/scrape.log"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

# Always append output to the log file
exec >> "$LOG_FILE" 2>&1

# Target group (default: macro)
GROUP="${1:-macro}"

echo "$LOG_PREFIX Starting podcast scrape (group: $GROUP)"

cd "$SCRAPER_DIR"

# Activate venv if it exists
if [[ -f "$SCRAPER_DIR/venv/bin/activate" ]]; then
  source "$SCRAPER_DIR/venv/bin/activate"
fi

# --- Step 1: Scrape feeds (fetch + transcribe) ---
echo "$LOG_PREFIX [step 1/3] Scraping podcast feeds..."
set +e
SCRAPE_OUTPUT=$(python3 src/cli.py scrape -g "$GROUP" -n 1 2>&1)
SCRAPE_EXIT=$?
set -e
echo "$SCRAPE_OUTPUT"

if [[ "$SCRAPE_EXIT" -ne 0 ]]; then
  echo "$LOG_PREFIX Scrape failed (exit: $SCRAPE_EXIT)"
fi

# --- Step 2: Export transcripts to text file ---
EXPORT_FILE="/tmp/podcasts_${GROUP}_export.txt"
DIGEST_TOOL_DIR="/Users/leonhaggarty/code/text-summary-tool/v1-python-instructions"
DIGEST_DIR="/tmp/podcasts_${GROUP}_digest"
DIGEST_FILE="${DIGEST_DIR}/podcasts_${GROUP}_export_digest.txt"

echo "$LOG_PREFIX [step 2/3] Exporting transcripts..."
set +e
python3 src/cli.py export -g "$GROUP" -l 168 -o "$EXPORT_FILE" 2>&1
EXPORT_EXIT=$?
set -e

DIGEST_FLAG=""
if [[ "$EXPORT_EXIT" -eq 0 && -f "$EXPORT_FILE" && -s "$EXPORT_FILE" ]]; then
  # --- Step 3: Run text-summary-tool digest ---
  echo "$LOG_PREFIX [step 3/3] Running digest tool..."
  mkdir -p "$DIGEST_DIR"
  set +e
  python3 "$DIGEST_TOOL_DIR/book_tool.py" digest "$EXPORT_FILE" -o "$DIGEST_DIR" --delimiter="---" 2>&1
  DIGEST_EXIT=$?
  set -e

  if [[ "$DIGEST_EXIT" -eq 0 && -f "$DIGEST_FILE" ]]; then
    echo "$LOG_PREFIX [digest] Digest created: $DIGEST_FILE"
    DIGEST_FLAG="$DIGEST_FILE"
  else
    echo "$LOG_PREFIX [digest] Digest failed (exit: $DIGEST_EXIT)"
  fi
else
  echo "$LOG_PREFIX [export] Export failed or empty (exit: $EXPORT_EXIT)"
fi

# --- Step 4: AI summarization via Cursor Agent CLI ---
# Try the Cursor Agent CLI first (cheaper model plan). If it fails, the calling
# Open Claw cron agent will fall back to its own AI for summarization.
OPENCLAW="/Users/leonhaggarty/.nvm/versions/node/v24.13.0/bin/openclaw"
TG_TARGET="6113620394"
AGENT_BIN="$HOME/.local/bin/agent"
SUMMARY_FILE="/tmp/podcasts_${GROUP}_summary.txt"

SUMMARY_OK=false

if [[ -n "$DIGEST_FLAG" && -f "$DIGEST_FLAG" ]]; then
  echo "$LOG_PREFIX [step 4/4] Summarizing digest via Cursor Agent CLI..."

  # Write the summarization prompt to a temp file (digest can be 20k+ words)
  PROMPT_FILE=$(mktemp /tmp/podcast-summary-prompt.XXXXXX)
  cat > "$PROMPT_FILE" <<PROMPT_EOF
Read the podcast digest below and produce a concise briefing (300-500 words).
For each podcast/author, highlight the key topics discussed, notable insights,
and any actionable takeaways. Write as a natural briefing, not bullet points
of raw transcript. Do NOT include any preamble like "Here is the summary".
Just output the briefing text directly.

--- DIGEST START ---
$(cat "$DIGEST_FLAG")
--- DIGEST END ---
PROMPT_EOF

  if [[ -x "$AGENT_BIN" ]]; then
    # Use expect to allocate a PTY (agent CLI requires it)
    EXPECT_SCRIPT=$(mktemp /tmp/podcast-summary-expect.XXXXXX)
    cat > "$EXPECT_SCRIPT" <<'EXPECT_EOF'
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
    expect "$EXPECT_SCRIPT" "$PROMPT_FILE" "$AGENT_BIN" > "$SUMMARY_FILE" 2>/dev/null
    AGENT_EXIT=$?
    set -e
    rm -f "$EXPECT_SCRIPT" "$PROMPT_FILE"

    if [[ "$AGENT_EXIT" -eq 0 && -s "$SUMMARY_FILE" ]]; then
      echo "$LOG_PREFIX [summary] Cursor Agent CLI succeeded"
      SUMMARY_OK=true
    else
      AGENT_FAIL_REASON="exit code $AGENT_EXIT"
      [[ "$AGENT_EXIT" -eq 1 ]] && grep -q "AGENT_TIMEOUT" "$SUMMARY_FILE" 2>/dev/null && AGENT_FAIL_REASON="timed out after 120s"
      echo "$LOG_PREFIX [summary] Cursor Agent CLI failed ($AGENT_FAIL_REASON), flagging for Open Claw fallback"
      rm -f "$SUMMARY_FILE"
    fi
  else
    AGENT_FAIL_REASON="agent binary not found at $AGENT_BIN"
    echo "$LOG_PREFIX [summary] $AGENT_FAIL_REASON, flagging for Open Claw fallback"
    rm -f "$PROMPT_FILE"
  fi
fi

# --- Send results ---
if [[ "$SUMMARY_OK" == "true" && -s "$SUMMARY_FILE" ]]; then
  # Cursor Agent produced a summary — send it directly to Telegram
  SUMMARY_CONTENT=$(head -c 4000 "$SUMMARY_FILE")
  if [[ -x "$OPENCLAW" ]]; then
    "$OPENCLAW" message send \
      --channel telegram \
      --target "$TG_TARGET" \
      -m "Podcast Digest ($GROUP):

$SUMMARY_CONTENT" \
      2>/dev/null || true
    echo "$LOG_PREFIX [telegram] Summary sent via Cursor Agent"
  fi
  echo "SUMMARY_FILE: $SUMMARY_FILE"
  echo "SUMMARY_SOURCE: cursor-agent"
elif [[ -n "$DIGEST_FLAG" && -f "$DIGEST_FLAG" ]]; then
  # Cursor Agent failed — notify user, then signal Open Claw to do fallback summarization
  if [[ -x "$OPENCLAW" ]]; then
    "$OPENCLAW" message send \
      --channel telegram \
      --target "$TG_TARGET" \
      -m "[Podcast pipeline] Cursor Agent summarization failed (${AGENT_FAIL_REASON:-unknown}). Falling back to Open Claw AI. Digest is ready and will be summarized shortly." \
      2>/dev/null || true
  fi
  echo "$LOG_PREFIX [result] Digest ready (Cursor Agent failed: ${AGENT_FAIL_REASON:-unknown}) — Open Claw agent should summarize: $DIGEST_FLAG"
  echo "DIGEST_FILE: $DIGEST_FLAG"
  echo "AGENT_FAIL_REASON: ${AGENT_FAIL_REASON:-unknown}"
  echo "SUMMARY_SOURCE: needs-fallback"
elif [[ "$SCRAPE_EXIT" -ne 0 ]] && [[ -x "$OPENCLAW" ]]; then
  "$OPENCLAW" message send \
    --channel telegram \
    --target "$TG_TARGET" \
    -m "Podcast scrape FAILED ($GROUP, exit $SCRAPE_EXIT). Check ~/code/podcast-scraper/scrape.log" \
    2>/dev/null || true
fi

# --- Store summary in MongoDB (if one was generated) ---
if [[ "$SUMMARY_OK" == "true" && -s "$SUMMARY_FILE" ]]; then
  TWITTER_SCRAPER_DIR="/Users/leonhaggarty/code/twitter-scraper"
  if [[ -f "$TWITTER_SCRAPER_DIR/src/store-summary.ts" ]]; then
    echo "$LOG_PREFIX [mongo] Storing summary in MongoDB..."
    (
      cd "$TWITTER_SCRAPER_DIR" \
      && bun run src/store-summary.ts -- \
        --group "$GROUP" --source podcast \
        --summary-file "$SUMMARY_FILE" \
        -m "${MONGO_URI:-${ATLAS_URI:-}}" 2>&1
    ) || echo "$LOG_PREFIX [mongo] Summary storage failed (non-fatal)"
  fi
fi

# --- Audio Digest: generate audio version ---
AUDIO_DIGEST_DIR="/Users/leonhaggarty/code/audio-digest"
if [[ -d "$AUDIO_DIGEST_DIR/venv" ]]; then
  AUDIO_SOURCE=""
  if [[ -s "$SUMMARY_FILE" ]]; then
    AUDIO_SOURCE="$SUMMARY_FILE"
    echo "$LOG_PREFIX [audio] Generating audio from AI summary..."
  elif [[ -f "$DIGEST_FILE" ]]; then
    AUDIO_SOURCE="$DIGEST_FILE"
    echo "$LOG_PREFIX [audio] Generating audio from raw digest (no summary available)..."
  fi
  if [[ -n "$AUDIO_SOURCE" ]]; then
    (
      cd "$AUDIO_DIGEST_DIR" \
      && source venv/bin/activate \
      && python -m engine.cli generate "$AUDIO_SOURCE" --source podcast --group "$GROUP" 2>&1
    ) || echo "$LOG_PREFIX [audio] Audio generation failed (non-fatal)"
  fi
fi

echo "$LOG_PREFIX Finished (exit: $SCRAPE_EXIT)"
exit "$SCRAPE_EXIT"
