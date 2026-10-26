#!/usr/bin/env python3
"""Generate the core fixture matrix for manual QA.

Usage: python tests/fixtures/make_fixtures.py <output-directory>
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tests.util import find_ffmpeg, make_clip  # noqa: E402


def run(ffmpeg: str, args: list[str]) -> None:
    result = subprocess.run(
        [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", *args],
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr or result.stdout)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: python tests/fixtures/make_fixtures.py <output-directory>", file=sys.stderr)
        return 2
    ffmpeg = find_ffmpeg()
    if ffmpeg is None:
        print("ffmpeg not found", file=sys.stderr)
        return 3
    out = Path(sys.argv[1]).expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)

    make_clip(ffmpeg, out / "clip.mp4", duration=5.0, size="320x240", fps=30)
    make_clip(ffmpeg, out / "clip_noaudio.mp4", duration=5.0, size="320x240", fps=30, audio=False)
    make_clip(ffmpeg, out / "clip_long.mp4", duration=20.0, size="320x240", fps=30)

    srt = out / "subs.srt"
    srt.write_text(
        "1\n00:00:00,000 --> 00:00:02,000\nFirst subtitle\n\n"
        "2\n00:00:02,000 --> 00:00:05,000\nSecond subtitle\n",
        encoding="utf-8",
    )
    chapters = out / "chapters.txt"
    chapters.write_text(
        ";FFMETADATA1\n"
        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=2500\ntitle=Chapter 1\n"
        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=2500\nEND=5000\ntitle=Chapter 2\n",
        encoding="utf-8",
    )
    run(
        ffmpeg,
        [
            "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-i", str(srt),
            "-f", "ffmetadata", "-i", str(chapters),
            "-t", "5",
            "-map", "0:v:0", "-map", "1:a:0", "-map", "2:0",
            "-map_metadata", "3", "-map_chapters", "3",
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "20",
            "-pix_fmt", "yuv420p",
            "-c:a", "libmp3lame", "-b:a", "128k",
            "-c:s", "srt",
            str(out / "clip_subs.mkv"),
        ],
    )
    odd_raw = out / "clip_odd.rgb"
    odd_raw.write_bytes(bytes(321 * 241 * 3 * 30))
    try:
        run(
            ffmpeg,
            [
                "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "321x241",
                "-r", "30", "-i", str(odd_raw), "-frames:v", "30",
                "-c:v", "ffv1", "-pix_fmt", "bgr0",
                str(out / "clip_odd.mkv"),
            ],
        )
    finally:
        odd_raw.unlink(missing_ok=True)
    run(
        ffmpeg,
        [
            "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30",
            "-t", "1",
            "-c:v", "libx265", "-preset", "ultrafast", "-crf", "28",
            "-pix_fmt", "yuv420p10le",
            "-x265-params", "log-level=error",
            str(out / "clip_10bit.mkv"),
        ],
    )

    for path in sorted(out.iterdir()):
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
