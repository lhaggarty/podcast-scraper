# Podcast Scraper

A Python CLI tool that fetches podcast RSS feeds, transcribes episodes with [faster-whisper](https://github.com/SYSTRAN/faster-whisper), and exports transcripts for AI summarization via the [text-summary-tool](https://github.com/lhaggarty/text-summary-tool) pipeline.

---

## Table of Contents

- [Pipeline](#pipeline)
- [Prerequisites](#prerequisites)
- [Setup](#setup)
- [Configuration](#configuration)
- [CLI Reference](#cli-reference)
  - [scrape](#scrape)
  - [adhoc](#adhoc)
  - [export](#export)
  - [list](#list)
- [Automated Pipeline (scrape-podcasts.sh)](#automated-pipeline-scrape-podcastssh)
- [Features](#features)
- [Database](#database)
- [Project Structure](#project-structure)

---

## Pipeline

```
RSS feeds → podcast-scraper (fetch + transcribe) → SQLite
  → export → text-summary-tool digest → AI summary → Telegram
```

---

## Prerequisites

| Dependency | Notes |
|------------|-------|
| Python 3.10+ | Runtime |
| [faster-whisper](https://github.com/SYSTRAN/faster-whisper) | Audio transcription (CPU or GPU) |
| [feedparser](https://feedparser.readthedocs.io/) | RSS/Atom feed parsing |
| [requests](https://docs.python-requests.org/) | HTTP client for downloads |

---

## Setup

```bash
cd podcast-scraper
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

---

## Configuration

### feeds.json

Feeds are organized by group. Each group is a list of feed objects with `name` and `feed_url`:

```json
{
  "macro": [
    {
      "name": "The Grant Williams Podcast",
      "feed_url": "https://feed.podbean.com/ttmygh/feed.xml"
    },
    {
      "name": "Redefining Energy",
      "feed_url": "https://www.spreaker.com/show/3170008/episodes/feed"
    }
  ],
  "crypto": [
    {
      "name": "On The Brink with Castle Island",
      "feed_url": "https://rss.libsyn.com/shows/214379/destinations/1552766.xml"
    }
  ]
}
```

Use `-g <group>` to target a specific group. If omitted, all groups are processed.

### Default paths

| Resource | Default path | Override |
|----------|-------------|---------|
| Database | `data/podcasts.db` | `--db <path>` |
| Feeds config | `feeds.json` | `-f <path>` |
| Audio cache | `audio_cache/` | `--cache-dir <path>` |

All directories are created automatically if they don't exist.

---

## CLI Reference

### scrape

```bash
python3 src/cli.py scrape [options]
```

Fetch RSS feeds, download audio, and transcribe new episodes.

| Flag | Default | Description |
|------|---------|-------------|
| `-f, --feeds-file <path>` | `feeds.json` | Path to feeds configuration |
| `-g, --group <name>` | all groups | Feed group to scrape |
| `-n, --max-episodes <N>` | `10` | Max episodes to check per feed (already-stored are skipped) |
| `--db <path>` | `data/podcasts.db` | SQLite database path |
| `--cache-dir <path>` | `audio_cache/` | Audio download cache directory |
| `--model-size <size>` | `base` | Whisper model: `tiny`, `base`, `small`, `medium`, `large-v3` |

```bash
# Scrape all groups, check up to 10 episodes per feed
python3 src/cli.py scrape

# Scrape only the macro group, 1 episode per feed
python3 src/cli.py scrape -g macro -n 1

# Use a larger whisper model for better accuracy
python3 src/cli.py scrape -g crypto --model-size medium
```

### adhoc

```bash
python3 src/cli.py adhoc <url> [options]
```

One-shot scrape of any RSS feed URL. Transcribes, exports, and optionally runs `text-summary-tool digest` in a single command.

| Flag | Default | Description |
|------|---------|-------------|
| `<url>` (positional) | — | RSS feed URL (required) |
| `--name <name>` | auto-inferred from URL | Feed display name |
| `-n, --max-episodes <N>` | `1` | Max episodes to transcribe |
| `-o, --output <path>` | `/tmp/podcasts_adhoc_export.txt` | Export file path |
| `--digest-dir <path>` | `/tmp/podcasts_adhoc_digest` | Digest output directory |
| `--db <path>` | `data/podcasts.db` | SQLite database path |
| `--cache-dir <path>` | `audio_cache/` | Audio cache directory |
| `--model-size <size>` | `base` | Whisper model size |

```bash
# Quick one-off transcription + digest
python3 src/cli.py adhoc https://feed.podbean.com/ttmygh/feed.xml

# Custom name, grab 2 episodes
python3 src/cli.py adhoc https://example.com/feed.xml --name "My Podcast" -n 2
```

If `text-summary-tool` is installed at `../text-summary-tool/`, the adhoc command automatically runs the digest tool on the exported transcript and prints the `DIGEST_FILE` path.

### export

```bash
python3 src/cli.py export [options]
```

Export recent transcripts from the database to a text file, formatted for `text-summary-tool digest`.

| Flag | Default | Description |
|------|---------|-------------|
| `-f, --feeds-file <path>` | `feeds.json` | Path to feeds config (used with `-g`) |
| `-g, --group <name>` | all feeds | Feed group to export |
| `-l, --lookback <hours>` | `168` (7 days) | How far back to look for episodes |
| `-o, --output <path>` | `/tmp/podcasts_{group}_export.txt` | Output file path |
| `--db <path>` | `data/podcasts.db` | SQLite database path |

```bash
# Export all episodes from the last 7 days
python3 src/cli.py export -o /tmp/podcasts_export.txt

# Export only the macro group
python3 src/cli.py export -g macro -o /tmp/podcasts_macro_export.txt

# Export with a 2-week lookback
python3 src/cli.py export -g macro -l 336
```

#### Export format

Episodes are separated by `---` delimiters, compatible with `text-summary-tool digest --delimiter="---"`:

```
[The Grant Williams Podcast]: Things That Make You Go Hmm (2026-02-08)
[transcript text...]
---
[Redefining Energy]: Ep 247 - Energy Transition Update (2026-02-06)
[transcript text...]
```

The `[Feed Name]:` prefix is auto-detected by the digest tool's author pattern matching.

### list

```bash
python3 src/cli.py list [options]
```

List stored episodes (metadata only, no transcripts).

| Flag | Default | Description |
|------|---------|-------------|
| `--db <path>` | `data/podcasts.db` | SQLite database path |
| `--limit <N>` | `50` | Max episodes to display |

```bash
python3 src/cli.py list
python3 src/cli.py list --limit 10
```

Output columns: Title, Feed, Words, Source, Scraped At.

---

## Automated Pipeline (scrape-podcasts.sh)

The shell script runs the full pipeline end-to-end, with AI summarization and Telegram notification.

### Steps

```
Step 1: Scrape feeds (python3 src/cli.py scrape -g GROUP -n 1)
Step 2: Export transcripts (python3 src/cli.py export -g GROUP -l 168)
Step 3: Run text-summary-tool digest on the export file
Step 4: AI summarization via Cursor Agent CLI (with Open Claw fallback)
  → Send summary to Telegram
```

### Usage

```bash
# Default group (macro)
./scrape-podcasts.sh

# Specific group
./scrape-podcasts.sh crypto
```

### Summarization strategy

1. **Primary**: Cursor Agent CLI (`~/.local/bin/agent`) with `gemini-3-pro` model and a 120-second timeout
2. **Fallback**: If Cursor Agent fails (timeout, missing binary, error), the script signals Open Claw to perform fallback summarization using the digest file

### Logging

All output is appended to `scrape.log` via `exec >> "$LOG_FILE" 2>&1`. Works the same whether called manually, from crontab, or from Open Claw.

### Error handling

- Scrape failures don't block the export/digest steps (prior episodes may still be exportable)
- Export failures prevent the digest step (nothing to process)
- Summarizer failures trigger an Open Claw fallback notification via Telegram
- The Telegram notification includes the summary on success, or an error alert on failure

---

## Features

### Podcast 2.0 transcript support

The scraper checks RSS feeds for [Podcast 2.0 transcript links](https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/1.0.md#transcript) before falling back to audio transcription. This is faster and more accurate when available.

Transcription strategy per episode:
1. Check for a `<podcast:transcript>` element in the RSS entry
2. If found, download the transcript directly (source: `podcast2.0`)
3. If not found, download the audio and transcribe with faster-whisper (source: `whisper`)

### Audio caching

Audio files are cached in `audio_cache/` using a SHA-256 hash of the URL as the filename. Subsequent runs skip the download if the cached file exists.

### Deduplication

Episodes are identified by their RSS `<guid>`. Already-stored episodes are skipped automatically. If an episode is re-processed, the transcript and metadata are updated (upsert behavior).

---

## Database

SQLite database at `data/podcasts.db` with a single `episodes` table.

### Schema

| Column | Type | Description |
|--------|------|-------------|
| `id` | TEXT (PK) | RSS guid (unique identifier) |
| `feed_name` | TEXT | Feed display name |
| `feed_url` | TEXT | RSS feed URL |
| `title` | TEXT | Episode title |
| `published_at` | TEXT | Publication date (RFC 2822 or ISO) |
| `audio_url` | TEXT | Audio file URL |
| `audio_path` | TEXT | Local cached audio path |
| `transcript` | TEXT | Full transcript text |
| `transcript_source` | TEXT | `podcast2.0` or `whisper` |
| `scraped_at` | TEXT | ISO timestamp of when we processed it |
| `word_count` | INTEGER | Transcript word count |

### Indexes

| Index | Column(s) | Purpose |
|-------|-----------|---------|
| `idx_episodes_feed` | `feed_name` | Filter by feed |
| `idx_episodes_scraped` | `scraped_at` | Lookback queries |

---

## Project Structure

```
podcast-scraper/
├── src/
│   ├── __init__.py        # Package init
│   ├── cli.py             # CLI entry point (argparse, subcommands)
│   ├── db.py              # SQLite persistence (schema, CRUD)
│   ├── export.py          # Export transcripts to text file
│   ├── feed.py            # RSS parsing, Podcast 2.0 transcript detection
│   └── transcribe.py      # Audio download + faster-whisper transcription
├── scrape-podcasts.sh     # Full pipeline script (scrape + digest + summarize + Telegram)
├── feeds.json             # Feed configuration (grouped by category)
├── requirements.txt       # Python dependencies
├── data/                  # SQLite database (gitignored)
│   └── podcasts.db
├── audio_cache/           # Cached audio downloads (gitignored)
├── scrape.log             # Pipeline log output (gitignored)
├── .gitignore
└── README.md
```

---

## License

MIT
