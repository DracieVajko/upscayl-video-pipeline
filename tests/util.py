import json
import shutil
import subprocess
import sys
import unittest
from pathlib import Path


def find_ffmpeg() -> str | None:
    found = shutil.which("ffmpeg")
    if found:
        return found
    sibling = Path(__file__).resolve().parents[1].parent / (
        "ffmpeg.exe" if sys.platform.startswith("win") else "ffmpeg"
    )
    candidates = [
        sibling,
        Path("C:/FFMPEG/ffmpeg.exe"),
        Path("C:/ffmpeg/bin/ffmpeg.exe"),
        Path("/usr/bin/ffmpeg"),
        Path("/usr/local/bin/ffmpeg"),
        Path("/opt/homebrew/bin/ffmpeg"),
    ]
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    return None


def find_ffprobe(ffmpeg: str) -> str:
    path = Path(ffmpeg)
    name = "ffprobe.exe" if path.name.lower().endswith(".exe") else "ffprobe"
    sibling = path.with_name(name)
    if sibling.is_file():
        return str(sibling)
    found = shutil.which("ffprobe")
    if found:
        return found
    raise unittest.SkipTest("ffprobe not available")


def make_clip(
    ffmpeg: str,
    path: Path,
    *,
    duration: float,
    size: str,
    fps: int,
    audio: bool = True,
    video_codec: str = "libx264",
) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    frames = int(round(duration * fps))
    args = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-f",
        "lavfi",
        "-i",
        f"testsrc2=size={size}:rate={fps}",
    ]
    if audio:
        args += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000"]
    args += [
        "-frames:v",
        str(frames),
        "-t",
        f"{duration:.3f}",
        "-c:v",
        video_codec,
        "-preset",
        "ultrafast",
        "-crf",
        "18",
        "-pix_fmt",
        "yuv420p",
    ]
    if audio:
        args += ["-c:a", "aac", "-b:a", "128k", "-shortest"]
    else:
        args += ["-an"]
    args.append(str(path))
    result = subprocess.run(
        args,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr or result.stdout)


def ffprobe_json(ffprobe: str, path: Path) -> dict:
    result = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
            str(path),
        ],
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr or result.stdout)
    return json.loads(result.stdout)
