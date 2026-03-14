#!/usr/bin/env bash
# snipcast-submit.sh — Submit a podcast episode URL to Snipcast.io for AI summary.
# Uses Playwright to automate browser submission (Cloudflare Turnstile captcha
# requires a real browser session).
#
# Usage:
#   ./snipcast-submit.sh <episode-url> [email]
#
# Examples:
#   ./snipcast-submit.sh "https://open.spotify.com/episode/3bEF157FM2F0O3kCJ9zYBF"
#   ./snipcast-submit.sh "https://open.spotify.com/episode/3bEF157FM2F0O3kCJ9zYBF" "you@example.com"

set -euo pipefail

EPISODE_URL="${1:-}"
EMAIL="${2:-lhaggarty@ryerson.ca}"
PYTHON="/Users/leonhaggarty/code/social-post/venv/bin/python3"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-60}"

if [[ -z "$EPISODE_URL" ]]; then
  echo "Usage: $0 <episode-url> [email]"
  echo "  Supported: Spotify, Apple Podcasts, Pocket Casts, Overcast"
  exit 1
fi

exec "$PYTHON" - "$EPISODE_URL" "$EMAIL" "$TIMEOUT_SECONDS" << 'PYEOF'
import sys
import time

episode_url = sys.argv[1]
email = sys.argv[2]
timeout = int(sys.argv[3])

from playwright.sync_api import sync_playwright

print(f"[snipcast] Submitting: {episode_url}")
print(f"[snipcast] Email: {email}")

with sync_playwright() as pw:
    browser = pw.chromium.launch(headless=True)
    page = browser.new_page()

    page.goto("https://snipcast.io", wait_until="load", timeout=30000)
    page.wait_for_timeout(3000)

    url_input = page.locator('input[type="url"]')
    url_input.fill(episode_url)

    email_input = page.locator('input[type="email"]')
    email_input.fill(email)

    # Wait for Turnstile to solve (the iframe loads and auto-solves)
    print("[snipcast] Waiting for Turnstile captcha to resolve...")
    deadline = time.time() + timeout
    turnstile_ready = False
    while time.time() < deadline:
        # Turnstile sets a hidden input or the submit button becomes enabled
        # Check for the turnstile success callback by looking for the response
        result = page.evaluate("""() => {
            const frames = document.querySelectorAll('iframe[src*="turnstile"]');
            if (frames.length === 0) return 'no-iframe';
            // Check if turnstile widget shows success
            const container = document.querySelector('[data-turnstile-callback]') 
                || document.querySelector('.cf-turnstile');
            if (container) {
                const response = container.querySelector('[name="cf-turnstile-response"]');
                if (response && response.value) return 'ready';
            }
            return 'waiting';
        }""")
        if result == "ready":
            turnstile_ready = True
            break
        if result == "no-iframe":
            # Turnstile might not be loaded yet or might not be required
            turnstile_ready = True
            break
        page.wait_for_timeout(1000)

    if not turnstile_ready:
        print("[snipcast] WARNING: Turnstile may not have resolved, attempting submit anyway")

    submit_btn = page.locator('button[type="submit"]')
    submit_btn.click()

    # Wait for success response
    print("[snipcast] Submitted, waiting for confirmation...")
    page.wait_for_timeout(5000)

    # Check for success message in the page
    body_text = page.text_content("body") or ""
    if "analyzing" in body_text.lower() or "check your" in body_text.lower() or "inbox" in body_text.lower() or "minutes" in body_text.lower():
        print("[snipcast] SUCCESS — summary is being generated, check your email")
    elif "error" in body_text.lower() or "failed" in body_text.lower():
        # Try to get the error text
        print(f"[snipcast] POSSIBLE ERROR — page content suggests failure")
        page.screenshot(path="/tmp/snipcast-submit-error.png")
        print("[snipcast] Screenshot saved to /tmp/snipcast-submit-error.png")
    else:
        print("[snipcast] Submitted (could not confirm status from page)")
        page.screenshot(path="/tmp/snipcast-submit-result.png")
        print("[snipcast] Screenshot saved to /tmp/snipcast-submit-result.png")

    browser.close()

print("[snipcast] Done")
PYEOF
