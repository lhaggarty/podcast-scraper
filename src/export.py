"""Export transcripts to text files for the text-summary-tool pipeline."""

import os
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
