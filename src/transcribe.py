"""Audio download and transcription via faster-whisper."""

import hashlib
import os
import sys
from typing import Optional

import requests


def _episode_cache_path(audio_url: str, cache_dir: str) -> str:
    """Generate a deterministic cache filename from the audio URL."""
    url_hash = hashlib.sha256(audio_url.encode()).hexdigest()[:16]
    # Preserve the file extension
    ext = ".mp3"
    for candidate in (".mp3", ".m4a", ".ogg", ".wav", ".mp4"):
        if audio_url.lower().split("?")[0].endswith(candidate):
            ext = candidate
            break
    return os.path.join(cache_dir, f"{url_hash}{ext}")


def download_audio(audio_url: str, cache_dir: str) -> str:
    """Download audio to cache directory. Returns the local file path.

    Skips download if the file already exists in cache.
    """
    os.makedirs(cache_dir, exist_ok=True)
    local_path = _episode_cache_path(audio_url, cache_dir)

    if os.path.exists(local_path):
        print(f"  [cache hit] {os.path.basename(local_path)}")
        return local_path

    print(f"  [downloading] {audio_url[:100]}...")
    resp = requests.get(audio_url, stream=True, timeout=60)
    resp.raise_for_status()

    total = int(resp.headers.get("content-length", 0))
    downloaded = 0

    with open(local_path, "wb") as f:
        for chunk in resp.iter_content(chunk_size=1024 * 256):
            f.write(chunk)
            downloaded += len(chunk)
            if total > 0:
                pct = downloaded / total * 100
                mb = downloaded / (1024 * 1024)
                print(f"\r  [downloading] {mb:.1f} MB ({pct:.0f}%)", end="", flush=True)

    if total > 0:
        print()  # newline after progress

    size_mb = os.path.getsize(local_path) / (1024 * 1024)
    print(f"  [saved] {os.path.basename(local_path)} ({size_mb:.1f} MB)")
    return local_path


def transcribe_audio(audio_path: str, model_size: str = "base") -> str:
    """Transcribe an audio file using faster-whisper.

    Args:
        audio_path: Path to the audio file.
        model_size: Whisper model size (tiny, base, small, medium, large-v3).

    Returns:
        Full transcript as a string.
    """
    # Import here so the module can be loaded without faster-whisper installed
    # (e.g. when only using the export/list commands)
    from faster_whisper import WhisperModel

    print(f"  [transcribing] model={model_size}, file={os.path.basename(audio_path)}")
    print(f"  [transcribing] This may take a while for long episodes...")

    model = WhisperModel(model_size, device="cpu", compute_type="int8")
    segments, info = model.transcribe(audio_path, beam_size=5)

    print(f"  [transcribing] Detected language: {info.language} (prob: {info.language_probability:.2f})")

    parts = []
    for segment in segments:
        parts.append(segment.text.strip())

    transcript = " ".join(parts)
    word_count = len(transcript.split())
    print(f"  [transcribed] {word_count} words")

    return transcript
