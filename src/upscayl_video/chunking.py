"""Time-based chunk planning and segment concatenation."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

from .errors import EncodeError, ValidationError
from .util import Logger, run_command


@dataclass(frozen=True)
class Chunk:
    index: int
    start: float
    end: float
    start_frame: int
    frame_count: int


def plan_chunks(duration: float, fps: float, chunk_seconds: int) -> list[Chunk]:
    if chunk_seconds < 10:
        raise ValidationError("Chunk length must be at least 10 seconds")
    if duration <= 0 or fps <= 0:
        return []
    total_frames = int(round(duration * fps))
    chunks: list[Chunk] = []
    start = 0.0
    index = 1
    while start < duration - 1e-9:
        end = min(duration, start + chunk_seconds)
        start_frame = int(round(start * fps)) + 1
        end_frame = int(round(end * fps))
        frame_count = end_frame - start_frame + 1
        if frame_count > 0:
            chunks.append(Chunk(index, start, end, start_frame, frame_count))
            index += 1
        start = end
    if sum(chunk.frame_count for chunk in chunks) != total_frames:
        raise ValidationError("Internal chunk frame accounting mismatch")
    return chunks


def concat_list(segments: Sequence[Path], path: Path) -> Path:
    lines = []
    for segment in segments:
        text = str(Path(segment).resolve()).replace("'", "'\\''")
        lines.append(f"file '{text}'")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def concat_segments(
    ffmpeg: Path,
    segments: Sequence[Path],
    output: Path,
    logger: Logger,
) -> None:
    list_path = Path(output).with_suffix(".txt")
    concat_list(segments, list_path)
    command = [
        str(ffmpeg), "-hide_banner", "-nostdin", "-y",
        "-f", "concat", "-safe", "0", "-i", str(list_path),
        "-c", "copy", "-fflags", "+genpts", str(output),
    ]
    try:
        run_command(command, logger=logger)
    except Exception as exc:
        raise EncodeError(
            "Could not concatenate chunk segments.",
            hint=str(exc),
        ) from exc
