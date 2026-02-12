"""CLI entry point for the podcast scraper."""

import argparse
import os
import sys

# Allow running as `python3 src/cli.py` from the repo root
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
if REPO_DIR not in sys.path:
    sys.path.insert(0, REPO_DIR)

from src.feed import load_feeds, parse_feed, fetch_transcript
from src.transcribe import download_audio, transcribe_audio
from src import db
from src.export import export_transcripts


DEFAULT_DB = os.path.join(REPO_DIR, "data", "podcasts.db")
DEFAULT_FEEDS = os.path.join(REPO_DIR, "feeds.json")
DEFAULT_CACHE = os.path.join(REPO_DIR, "audio_cache")


def cmd_scrape(args):
    """Fetch feeds, download audio, transcribe new episodes."""
    feeds = load_feeds(args.feeds_file)
    conn = db.connect(args.db)

    # Filter to requested group or process all groups
    if args.group:
        if args.group not in feeds:
            print(f"Error: group '{args.group}' not found in {args.feeds_file}")
            print(f"Available groups: {', '.join(feeds.keys())}")
            sys.exit(1)
        groups_to_process = {args.group: feeds[args.group]}
    else:
        groups_to_process = feeds

    total_new = 0
    total_skipped = 0

    for group_name, feed_list in groups_to_process.items():
        print(f"\n=== Group: {group_name} ===")

        for feed_config in feed_list:
            feed_name = feed_config["name"]
            feed_url = feed_config["feed_url"]

            print(f"\n--- {feed_name} ---")
            print(f"  Feed: {feed_url}")

            try:
                episodes = parse_feed(feed_name, feed_url, max_episodes=args.max_episodes)
            except Exception as e:
                print(f"  [error] Failed to parse feed: {e}")
                continue

            print(f"  Found {len(episodes)} episode(s)")

            for ep in episodes:
                # Skip if already transcribed
                if db.episode_exists(conn, ep.id):
                    print(f"  [skip] Already stored: {ep.title}")
                    total_skipped += 1
                    continue

                print(f"  [new] {ep.title}")

                transcript = None
                transcript_source = None
                audio_path = None

                # Strategy 1: Check for Podcast 2.0 transcript
                if ep.transcript_url:
                    print(f"  [podcast2.0] Found transcript URL, downloading...")
                    transcript = fetch_transcript(ep.transcript_url)
                    if transcript:
                        transcript_source = "podcast2.0"
                        print(f"  [podcast2.0] Got transcript ({len(transcript.split())} words)")

                # Strategy 2: Download and transcribe audio
                if not transcript and ep.audio_url:
                    try:
                        audio_path = download_audio(ep.audio_url, args.cache_dir)
                        transcript = transcribe_audio(audio_path, model_size=args.model_size)
                        transcript_source = "whisper"
                    except Exception as e:
                        print(f"  [error] Transcription failed: {e}")
                        continue

                if not transcript:
                    print(f"  [skip] No audio or transcript available")
                    continue

                # Store in database
                db.store_episode(
                    conn,
                    episode_id=ep.id,
                    feed_name=ep.feed_name,
                    feed_url=ep.feed_url,
                    title=ep.title,
                    published_at=ep.published_at,
                    audio_url=ep.audio_url,
                    audio_path=audio_path,
                    transcript=transcript,
                    transcript_source=transcript_source,
                )
                total_new += 1
                print(f"  [stored] {ep.title}")

    conn.close()

    print(f"\n=== Done ===")
    print(f"New episodes: {total_new}")
    print(f"Skipped (already stored): {total_skipped}")

    return total_new


def cmd_export(args):
    """Export recent transcripts to a text file."""
    # Resolve feed names for the group if specified
    group_feeds = None
    if args.group:
        feeds = load_feeds(args.feeds_file)
        if args.group not in feeds:
            print(f"Error: group '{args.group}' not found in {args.feeds_file}")
            sys.exit(1)
        group_feeds = [f["name"] for f in feeds[args.group]]

    output_path = args.output or f"/tmp/podcasts_{args.group or 'all'}_export.txt"

    result = export_transcripts(
        db_path=args.db,
        output_path=output_path,
        lookback_hours=args.lookback,
        group_feeds=group_feeds,
    )

    if result["episode_count"] == 0:
        sys.exit(1)


def cmd_list(args):
    """List stored episodes."""
    conn = db.connect(args.db)
    episodes = db.list_episodes(conn, limit=args.limit)
    conn.close()

    if not episodes:
        print("No episodes stored yet.")
        return

    print(f"{'Title':<50} {'Feed':<30} {'Words':>8} {'Source':>10} {'Scraped At':<20}")
    print("-" * 125)
    for ep in episodes:
        title = ep["title"][:48]
        feed = ep["feed_name"][:28]
        words = ep.get("word_count", 0) or 0
        source = ep.get("transcript_source", "?")
        scraped = (ep.get("scraped_at") or "")[:19]
        print(f"{title:<50} {feed:<30} {words:>8,} {source:>10} {scraped:<20}")


def cmd_adhoc(args):
    """Ad-hoc: scrape a one-off RSS feed URL, transcribe, export, and run digest."""
    feed_url = args.url
    feed_name = args.name or _infer_feed_name(feed_url)
    conn = db.connect(args.db)

    print(f"\n=== Ad-hoc: {feed_name} ===")
    print(f"  Feed: {feed_url}")

    try:
        episodes = parse_feed(feed_name, feed_url, max_episodes=args.max_episodes)
    except Exception as e:
        print(f"  [error] Failed to parse feed: {e}")
        sys.exit(1)

    print(f"  Found {len(episodes)} episode(s)")

    new_count = 0
    for ep in episodes:
        if db.episode_exists(conn, ep.id):
            print(f"  [skip] Already stored: {ep.title}")
            continue

        print(f"  [new] {ep.title}")

        transcript = None
        transcript_source = None
        audio_path = None

        # Strategy 1: Podcast 2.0 transcript
        if ep.transcript_url:
            print(f"  [podcast2.0] Found transcript URL, downloading...")
            transcript = fetch_transcript(ep.transcript_url)
            if transcript:
                transcript_source = "podcast2.0"
                print(f"  [podcast2.0] Got transcript ({len(transcript.split())} words)")

        # Strategy 2: Download and transcribe audio
        if not transcript and ep.audio_url:
            try:
                audio_path = download_audio(ep.audio_url, args.cache_dir)
                transcript = transcribe_audio(audio_path, model_size=args.model_size)
                transcript_source = "whisper"
            except Exception as e:
                print(f"  [error] Transcription failed: {e}")
                continue

        if not transcript:
            print(f"  [skip] No audio or transcript available")
            continue

        db.store_episode(
            conn,
            episode_id=ep.id,
            feed_name=ep.feed_name,
            feed_url=ep.feed_url,
            title=ep.title,
            published_at=ep.published_at,
            audio_url=ep.audio_url,
            audio_path=audio_path,
            transcript=transcript,
            transcript_source=transcript_source,
        )
        new_count += 1
        print(f"  [stored] {ep.title}")

    conn.close()

    if new_count == 0:
        print("\nNo new episodes to process.")
        return

    # Export the transcript
    export_path = args.output or f"/tmp/podcasts_adhoc_export.txt"
    result = export_transcripts(
        db_path=args.db,
        output_path=export_path,
        lookback_hours=1,  # just the freshly scraped episodes
        group_feeds=[feed_name],
    )

    # Run text-summary-tool digest if available
    digest_tool = os.path.join(
        os.path.dirname(REPO_DIR),
        "text-summary-tool", "v1-python-instructions", "book_tool.py"
    )
    if os.path.exists(digest_tool) and result["episode_count"] > 0:
        import subprocess
        digest_dir = args.digest_dir or "/tmp/podcasts_adhoc_digest"
        os.makedirs(digest_dir, exist_ok=True)
        print(f"\nRunning text-summary-tool digest...")
        ret = subprocess.run(
            ["python3", digest_tool, "digest", export_path,
             "-o", digest_dir, "--delimiter=---"],
            capture_output=False,
        )
        if ret.returncode == 0:
            # Derive digest filename from export filename
            base = os.path.splitext(os.path.basename(export_path))[0]
            digest_file = os.path.join(digest_dir, f"{base}_digest.txt")
            if os.path.exists(digest_file):
                print(f"\nDIGEST_FILE: {digest_file}")
        else:
            print(f"\n[warn] Digest tool exited with code {ret.returncode}")
    else:
        if not os.path.exists(digest_tool):
            print(f"\n[info] text-summary-tool not found at {digest_tool}, skipping digest.")

    print(f"\n=== Ad-hoc complete ===")
    print(f"New episodes transcribed: {new_count}")
    print(f"Export: {export_path}")


def _infer_feed_name(url: str) -> str:
    """Try to infer a readable feed name from a URL."""
    from urllib.parse import urlparse
    parsed = urlparse(url)
    # Use the hostname minus common prefixes
    host = parsed.hostname or "unknown"
    for prefix in ("www.", "feed.", "feeds.", "rss."):
        if host.startswith(prefix):
            host = host[len(prefix):]
    # Use path segments if they look meaningful
    path_parts = [p for p in parsed.path.strip("/").split("/") if p and p != "feed.xml" and p != "feed" and p != "rss"]
    if path_parts:
        return f"{path_parts[0]} ({host})"
    return host


def main():
    parser = argparse.ArgumentParser(
        description="Podcast scraper — fetch, transcribe, and export podcast episodes"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # --- scrape ---
    p_scrape = subparsers.add_parser("scrape", help="Fetch feeds and transcribe new episodes")
    p_scrape.add_argument("-f", "--feeds-file", default=DEFAULT_FEEDS, help="Path to feeds.json")
    p_scrape.add_argument("-g", "--group", help="Feed group to scrape (default: all)")
    p_scrape.add_argument("-n", "--max-episodes", type=int, default=10, help="Max episodes to check per feed (default: 10, dedup skips already-stored)")
    p_scrape.add_argument("--db", default=DEFAULT_DB, help="SQLite database path")
    p_scrape.add_argument("--cache-dir", default=DEFAULT_CACHE, help="Audio cache directory")
    p_scrape.add_argument("--model-size", default="base", help="Whisper model size (tiny/base/small/medium/large-v3)")

    # --- adhoc ---
    p_adhoc = subparsers.add_parser("adhoc", help="Scrape a one-off RSS feed URL, transcribe, and digest")
    p_adhoc.add_argument("url", help="RSS feed URL")
    p_adhoc.add_argument("--name", help="Feed name (auto-inferred if omitted)")
    p_adhoc.add_argument("-n", "--max-episodes", type=int, default=1, help="Max episodes (default: 1)")
    p_adhoc.add_argument("-o", "--output", help="Export file path (default: /tmp/podcasts_adhoc_export.txt)")
    p_adhoc.add_argument("--digest-dir", help="Digest output dir (default: /tmp/podcasts_adhoc_digest)")
    p_adhoc.add_argument("--db", default=DEFAULT_DB, help="SQLite database path")
    p_adhoc.add_argument("--cache-dir", default=DEFAULT_CACHE, help="Audio cache directory")
    p_adhoc.add_argument("--model-size", default="base", help="Whisper model size (tiny/base/small/medium/large-v3)")

    # --- export ---
    p_export = subparsers.add_parser("export", help="Export recent transcripts to text file")
    p_export.add_argument("-f", "--feeds-file", default=DEFAULT_FEEDS, help="Path to feeds.json")
    p_export.add_argument("-g", "--group", help="Feed group to export")
    p_export.add_argument("-l", "--lookback", type=int, default=168, help="Lookback hours (default: 168 = 7 days)")
    p_export.add_argument("-o", "--output", help="Output file path (default: /tmp/podcasts_{group}_export.txt)")
    p_export.add_argument("--db", default=DEFAULT_DB, help="SQLite database path")

    # --- list ---
    p_list = subparsers.add_parser("list", help="List stored episodes")
    p_list.add_argument("--db", default=DEFAULT_DB, help="SQLite database path")
    p_list.add_argument("--limit", type=int, default=50, help="Max episodes to show")

    args = parser.parse_args()

    if args.command == "scrape":
        cmd_scrape(args)
    elif args.command == "adhoc":
        cmd_adhoc(args)
    elif args.command == "export":
        cmd_export(args)
    elif args.command == "list":
        cmd_list(args)


if __name__ == "__main__":
    main()
