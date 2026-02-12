# podcast-scraper

Fetches podcast RSS feeds, transcribes audio with faster-whisper, and exports transcripts for the text-summary-tool pipeline.

## Pipeline

```
podcast-scraper -> text-summary-tool digest -> Open Claw -> Telegram
```

## Setup

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

## Usage

```bash
# Scrape latest episode from all configured feeds
python3 src/cli.py scrape

# Scrape a specific group, up to 3 episodes per feed
python3 src/cli.py scrape -g macro -n 3

# Export recent transcripts to text file
python3 src/cli.py export -o /tmp/podcasts_macro_export.txt

# List stored episodes
python3 src/cli.py list
```

## Full pipeline (via shell script)

```bash
./scrape-podcasts.sh macro
```

This runs: scrape -> export -> text-summary-tool digest -> Open Claw notification.
