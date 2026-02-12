"""RSS feed parsing — fetch episodes from podcast feeds."""

import json
import hashlib
from dataclasses import dataclass, field
from time import mktime
from typing import Optional

import feedparser
import requests


@dataclass
class Episode:
    """A single podcast episode parsed from an RSS feed."""
    id: str                         # RSS guid (unique identifier)
    feed_name: str
    feed_url: str
    title: str
    published_at: Optional[str]     # ISO date string or None
    audio_url: Optional[str]
    transcript_url: Optional[str]   # Podcast 2.0 transcript URL if available
    transcript_text: Optional[str] = None


def _get_entry_timestamp(entry) -> float:
    """Extract a sortable timestamp from a feed entry, with fallbacks."""
    if entry.get("published_parsed"):
        return mktime(entry.published_parsed)
    if entry.get("updated_parsed"):
        return mktime(entry.updated_parsed)
    return 0


def _get_entry_date(entry) -> Optional[str]:
    """Extract a human-readable date string from a feed entry."""
    for field_name in ("published", "updated"):
        val = entry.get(field_name)
        if val:
            return val
    return None


def _get_audio_url(entry) -> Optional[str]:
    """Extract audio URL from RSS enclosures (preferred) or links."""
    # Prefer enclosures — purpose-built for podcast audio
    for enc in getattr(entry, "enclosures", []):
        href = enc.get("href") or enc.get("url")
        enc_type = enc.get("type", "")
        if href and ("audio" in enc_type or href.lower().endswith((".mp3", ".m4a", ".ogg", ".wav"))):
            return href

    # Fallback: scan links for audio types
    for link in entry.get("links", []):
        link_type = link.get("type", "")
        href = link.get("href", "")
        if "audio" in link_type or href.lower().endswith((".mp3", ".m4a", ".ogg", ".wav")):
            return href

    return None


def _get_transcript_url(entry) -> Optional[str]:
    """Check for Podcast 2.0 transcript in entry links."""
    for link in entry.get("links", []):
        if link.get("rel") == "transcript":
            return link.get("href")
    return None


def _get_episode_id(entry, feed_url: str) -> str:
    """Get a stable unique ID for an episode."""
    # Prefer the RSS guid
    guid = entry.get("id") or entry.get("guid")
    if guid:
        return guid
    # Fallback: hash of feed URL + title
    title = entry.get("title", "unknown")
    return hashlib.sha256(f"{feed_url}:{title}".encode()).hexdigest()[:32]


def fetch_transcript(url: str) -> Optional[str]:
    """Download a Podcast 2.0 transcript from a URL."""
    try:
        resp = requests.get(url, timeout=30)
        resp.raise_for_status()
        return resp.text
    except requests.RequestException:
        return None


def parse_feed(feed_name: str, feed_url: str, max_episodes: int = 1) -> list[Episode]:
    """Parse an RSS feed and return the latest episodes."""
    feed = feedparser.parse(feed_url)

    if feed.bozo and not feed.entries:
        raise ValueError(f"Failed to parse feed: {feed_url} — {feed.bozo_exception}")

    # Sort entries by date, newest first
    sorted_entries = sorted(feed.entries, key=_get_entry_timestamp, reverse=True)

    episodes = []
    for entry in sorted_entries[:max_episodes]:
        episode = Episode(
            id=_get_episode_id(entry, feed_url),
            feed_name=feed_name,
            feed_url=feed_url,
            title=entry.get("title", "Untitled"),
            published_at=_get_entry_date(entry),
            audio_url=_get_audio_url(entry),
            transcript_url=_get_transcript_url(entry),
        )
        episodes.append(episode)

    return episodes


def load_feeds(feeds_file: str) -> dict[str, list[dict]]:
    """Load feed configuration from a JSON file."""
    with open(feeds_file, "r") as f:
        return json.load(f)
