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

# --- Report results (Telegram notification is handled by the Open Claw agent) ---
# The cron agent reads the digest file and produces an AI summary before sending.
# This script only sends alerts for failures.
OPENCLAW="/Users/leonhaggarty/.nvm/versions/node/v24.13.0/bin/openclaw"
TG_TARGET="6113620394"

if [[ -n "$DIGEST_FLAG" && -f "$DIGEST_FLAG" ]]; then
  echo "$LOG_PREFIX [result] Digest ready: $DIGEST_FLAG"
  echo "DIGEST_FILE: $DIGEST_FLAG"
elif [[ "$SCRAPE_EXIT" -ne 0 ]] && [[ -x "$OPENCLAW" ]]; then
  # Only send Telegram for failures — the agent handles success notifications
  "$OPENCLAW" message send \
    --channel telegram \
    --target "$TG_TARGET" \
    -m "Podcast scrape FAILED ($GROUP, exit $SCRAPE_EXIT). Check ~/code/podcast-scraper/scrape.log" \
    2>/dev/null || true
fi

echo "$LOG_PREFIX Finished (exit: $SCRAPE_EXIT)"
exit "$SCRAPE_EXIT"
