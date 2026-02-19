"""Export transcripts to text files for the text-summary-tool pipeline."""

import os
import re
from collections import defaultdict
from typing import Optional

from . import db


DELIMITER = "---"


def _format_date(published_at: Optional[str]) -> str:
    """Extract a short date from the published_at string."""
    if not published_at:
        return "unknown date"
    # published_at can be full RFC 2822 or ISO — just grab the date portion
    # Try ISO format first (YYYY-MM-DD...)
    if len(published_at) >= 10 and published_at[4] == "-":
        return published_at[:10]
    # For RFC 2822 like "Mon, 10 Feb 2026 08:00:00 +0000", extract date parts
    try:
        from email.utils import parsedate_to_datetime
        dt = parsedate_to_datetime(published_at)
        return dt.strftime("%Y-%m-%d")
    except Exception:
        return published_at[:20]


def export_transcripts(
    db_path: str,
    output_path: str,
    lookback_hours: int = 168,
    group_feeds: Optional[list[str]] = None,
) -> dict:
    """Export recent transcripts to a text file in text-summary-tool format.

    Format (--- delimited, compatible with book_tool.py digest --delimiter="---"):

        [Feed Name]: Episode Title (2026-02-10)
        [transcript text...]
        ---
        [Feed Name]: Another Episode (2026-02-08)
        [transcript text...]

    The [Feed Name]: prefix matches text-summary-tool's auto author detection.

    Returns:
        Dict with export stats: episode_count, output_path, total_words.
    """
    conn = db.connect(db_path)

    if group_feeds:
        episodes = db.fetch_by_group(conn, group_feeds, lookback_hours)
    else:
        episodes = db.fetch_recent(conn, lookback_hours)

    conn.close()

    if not episodes:
        print("No episodes found within the lookback window.")
        return {"episode_count": 0, "output_path": output_path, "total_words": 0}

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)

    blocks = []
    total_words = 0

    for ep in episodes:
        transcript = ep.get("transcript", "")
        if not transcript:
            continue

        date_str = _format_date(ep.get("published_at"))
        header = f"[{ep['feed_name']}]: {ep['title']} ({date_str})"
        blocks.append(f"{header}\n{transcript}")
        total_words += ep.get("word_count", 0)

    content = f"\n{DELIMITER}\n".join(blocks)

    with open(output_path, "w") as f:
        f.write(content)
        f.write("\n")

    print(f"Exported {len(blocks)} episode(s) to {output_path}")
    print(f"Total words: {total_words:,}")

    return {
        "episode_count": len(blocks),
        "output_path": output_path,
        "total_words": total_words,
    }


def _normalize_excerpt_text(text: str) -> str:
    # Keep paragraphs, but collapse very noisy whitespace.
    t = text.replace("\r\n", "\n").replace("\r", "\n")
    t = re.sub(r"[ \t]+", " ", t)
    t = re.sub(r"\n{3,}", "\n\n", t)
    return t.strip()


def _excerpt_transcript(text: str, max_chars: int) -> str:
    t = _normalize_excerpt_text(text)
    if max_chars <= 0:
        return ""
    if len(t) <= max_chars:
        return t

    sep = "\n...\n"
    overhead = len(sep) * 2
    budget = max_chars - overhead
    if budget <= 0:
        return t[:max_chars].strip()

    part = max(200, budget // 3)
    head = t[:part]

    mid_start = max(0, (len(t) // 2) - (part // 2))
    mid = t[mid_start : mid_start + part]

    tail = t[-part:]

    return (head.strip() + sep + mid.strip() + sep + tail.strip()).strip()


def export_transcripts_json(
    db_path: str,
    lookback_hours: int = 168,
    group_feeds: Optional[list[str]] = None,
    max_episodes_total: int = 40,
    max_episodes_per_feed: int = 4,
    excerpt_chars: int = 10000,
) -> dict:
    """Export recent transcripts as a size-bounded JSON payload for server summarization.

    This is designed for piping into a server-side summarizer endpoint. It intentionally
    includes transcript excerpts (not full transcripts) to keep payloads bounded.
    """
    conn = db.connect(db_path)

    if group_feeds:
        episodes = db.fetch_by_group(conn, group_feeds, lookback_hours)
    else:
        episodes = db.fetch_recent(conn, lookback_hours)

    conn.close()

    selected = []
    per_feed_counts = defaultdict(int)

    for ep in episodes:
        if len(selected) >= max_episodes_total:
            break

        transcript = ep.get("transcript") or ""
        if not transcript.strip():
            continue

        feed_name = ep.get("feed_name") or ""
        if max_episodes_per_feed > 0 and per_feed_counts[feed_name] >= max_episodes_per_feed:
            continue

        selected.append(
            {
                "episodeId": ep.get("id"),
                "feedName": feed_name,
                "title": ep.get("title") or "",
                "publishedAt": ep.get("published_at"),
                "scrapedAt": ep.get("scraped_at"),
                "wordCount": ep.get("word_count") or 0,
                "transcriptExcerpt": _excerpt_transcript(transcript, excerpt_chars),
            }
        )
        per_feed_counts[feed_name] += 1

    return {
        "episodeCount": len(selected),
        "feedCount": len([k for k, v in per_feed_counts.items() if v > 0]),
        "lookbackHours": lookback_hours,
        "episodes": selected,
    }
