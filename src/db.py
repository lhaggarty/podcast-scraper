"""SQLite persistence for podcast episodes and transcripts."""

import os
import sqlite3
from datetime import datetime, timedelta, timezone
from typing import Optional


SCHEMA = """
CREATE TABLE IF NOT EXISTS episodes (
    id TEXT PRIMARY KEY,
    feed_name TEXT NOT NULL,
    feed_url TEXT NOT NULL,
    title TEXT NOT NULL,
    published_at TEXT,
    audio_url TEXT,
    audio_path TEXT,
    transcript TEXT,
    transcript_source TEXT,
    scraped_at TEXT NOT NULL,
    word_count INTEGER
);

CREATE INDEX IF NOT EXISTS idx_episodes_feed ON episodes(feed_name);
CREATE INDEX IF NOT EXISTS idx_episodes_scraped ON episodes(scraped_at);
"""


def connect(db_path: str) -> sqlite3.Connection:
    """Open (or create) the SQLite database and ensure schema exists."""
    os.makedirs(os.path.dirname(db_path) or ".", exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    return conn


def episode_exists(conn: sqlite3.Connection, episode_id: str) -> bool:
    """Check if an episode is already stored (by its RSS guid)."""
    row = conn.execute(
        "SELECT 1 FROM episodes WHERE id = ?", (episode_id,)
    ).fetchone()
    return row is not None


def store_episode(
    conn: sqlite3.Connection,
    episode_id: str,
    feed_name: str,
    feed_url: str,
    title: str,
    published_at: Optional[str],
    audio_url: Optional[str],
    audio_path: Optional[str],
    transcript: str,
    transcript_source: str,
) -> None:
    """Insert or update an episode with its transcript."""
    word_count = len(transcript.split()) if transcript else 0
    now = datetime.now(timezone.utc).isoformat()

    conn.execute(
        """
        INSERT INTO episodes (id, feed_name, feed_url, title, published_at,
                              audio_url, audio_path, transcript, transcript_source,
                              scraped_at, word_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            transcript = excluded.transcript,
            transcript_source = excluded.transcript_source,
            audio_path = excluded.audio_path,
            scraped_at = excluded.scraped_at,
            word_count = excluded.word_count
        """,
        (episode_id, feed_name, feed_url, title, published_at,
         audio_url, audio_path, transcript, transcript_source,
         now, word_count),
    )
    conn.commit()


def fetch_recent(
    conn: sqlite3.Connection,
    lookback_hours: int = 168,
    feed_name: Optional[str] = None,
) -> list[dict]:
    """Fetch episodes scraped within the lookback window."""
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=lookback_hours)).isoformat()

    if feed_name:
        rows = conn.execute(
            """SELECT * FROM episodes
               WHERE scraped_at >= ? AND feed_name = ?
               ORDER BY scraped_at DESC""",
            (cutoff, feed_name),
        ).fetchall()
    else:
        rows = conn.execute(
            """SELECT * FROM episodes
               WHERE scraped_at >= ?
               ORDER BY scraped_at DESC""",
            (cutoff,),
        ).fetchall()

    return [dict(row) for row in rows]


def fetch_by_group(
    conn: sqlite3.Connection,
    feed_names: list[str],
    lookback_hours: int = 168,
) -> list[dict]:
    """Fetch episodes for a list of feed names within the lookback window."""
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=lookback_hours)).isoformat()
    placeholders = ",".join("?" for _ in feed_names)
    rows = conn.execute(
        f"""SELECT * FROM episodes
            WHERE scraped_at >= ? AND feed_name IN ({placeholders})
            ORDER BY scraped_at DESC""",
        [cutoff] + feed_names,
    ).fetchall()
    return [dict(row) for row in rows]


def list_episodes(conn: sqlite3.Connection, limit: int = 50) -> list[dict]:
    """List recent episodes (metadata only, no transcript)."""
    rows = conn.execute(
        """SELECT id, feed_name, title, published_at, scraped_at,
                  transcript_source, word_count
           FROM episodes
           ORDER BY scraped_at DESC
           LIMIT ?""",
        (limit,),
    ).fetchall()
    return [dict(row) for row in rows]
