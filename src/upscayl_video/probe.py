"""Media metadata parsing and probing."""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from .errors import CommandError, ValidationError
from .util import Logger, run_command


@dataclass(frozen=True)
class StreamInfo:
    index: int
    codec_name: str
    channels: int | None = None
    bit_rate: int | None = None
    language: str | None = None
    title: str | None = None


@dataclass(frozen=True)
class MediaInfo:
    source: Path
    duration: float
    fps_num: int
    fps_den: int
    width: int
    height: int
    pix_fmt: str
    video_index: int
    audio: tuple[StreamInfo, ...]
    subtitles: tuple[StreamInfo, ...]
    chapters: int
    color_primaries: str | None
    color_trc: str | None
    colorspace: str | None
    color_range: str | None
    rotation: int
    hdr: bool
    source_size: int
    source_mtime: int

    @property
    def fps_decimal(self) -> float:
        if not self.fps_den:
            return 0.0
        return self.fps_num / self.fps_den

    @property
    def fps_rational(self) -> str:
        return f"{self.fps_num}/{self.fps_den}"

    @property
    def has_audio(self) -> bool:
        return bool(self.audio)

    @property
    def has_subtitles(self) -> bool:
        return bool(self.subtitles)


def parse_rational(value: str) -> tuple[int, int]:
    try:
        numerator, denominator = str(value).split("/", 1)
        numerator_i = int(numerator)
        denominator_i = int(denominator)
    except (TypeError, ValueError):
        return (0, 0)
    if numerator_i < 0 or denominator_i <= 0:
        return (0, 0)
    return (numerator_i, denominator_i)


def normalize_fps(avg: str | None, real: str | None) -> tuple[int, int]:
    for candidate in (avg, real):
        numerator, denominator = parse_rational(candidate or "")
        if numerator > 0 and denominator > 0:
            divisor = math.gcd(numerator, denominator)
            return (numerator // divisor, denominator // divisor)
    return (30, 1)


def is_hdr(color_trc: str | None, pix_fmt: str) -> bool:
    del pix_fmt  # 10-bit SDR is not HDR; only the transfer function decides.
    return (color_trc or "").strip().lower() in {"smpte2084", "arib-std-b67"}


def _clean(value: object) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text or text.lower() == "unknown":
        return None
    return text


def _as_int(value: object, default: int = 0) -> int:
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default


def _as_float(value: object, default: float = 0.0) -> float:
    try:
        return float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default


def _stream_info(stream: Mapping[str, Any]) -> StreamInfo:
    tags = stream.get("tags") or {}
    return StreamInfo(
        index=_as_int(stream.get("index")),
        codec_name=str(stream.get("codec_name") or "unknown"),
        channels=_as_int(stream.get("channels")) if stream.get("channels") is not None else None,
        bit_rate=_as_int(stream.get("bit_rate")) if stream.get("bit_rate") is not None else None,
        language=tags.get("language"),
        title=tags.get("title"),
    )


def _rotation(video: Mapping[str, Any]) -> int:
    for item in video.get("side_data_list") or []:
        if isinstance(item, Mapping) and "rotation" in item:
            return _as_int(item.get("rotation")) % 360
    tags = video.get("tags") or {}
    if "rotate" in tags:
        return _as_int(tags.get("rotate")) % 360
    return 0


def media_info_from_json(source: Path, data: Mapping[str, Any]) -> MediaInfo:
    streams = data.get("streams") or []
    video = next(
        (stream for stream in streams if stream.get("codec_type") == "video"),
        None,
    )
    if video is None:
        raise ValidationError(f"No video stream found in: {source}")

    format_info = data.get("format") or {}
    duration = _as_float(format_info.get("duration"), None) or _as_float(
        video.get("duration"), 0.0
    )
    fps_num, fps_den = normalize_fps(
        video.get("avg_frame_rate"),
        video.get("r_frame_rate"),
    )
    color_trc = _clean(video.get("color_transfer"))
    pix_fmt = str(video.get("pix_fmt") or "unknown")
    source_path = Path(source)
    exists = source_path.exists()

    audio = tuple(
        _stream_info(stream)
        for stream in streams
        if stream.get("codec_type") == "audio"
    )
    subtitles = tuple(
        _stream_info(stream)
        for stream in streams
        if stream.get("codec_type") == "subtitle"
    )

    return MediaInfo(
        source=source_path,
        duration=duration,
        fps_num=fps_num,
        fps_den=fps_den,
        width=_as_int(video.get("width")),
        height=_as_int(video.get("height")),
        pix_fmt=pix_fmt,
        video_index=_as_int(video.get("index")),
        audio=audio,
        subtitles=subtitles,
        chapters=len(data.get("chapters") or []),
        color_primaries=_clean(video.get("color_primaries")),
        color_trc=color_trc,
        colorspace=_clean(video.get("color_space")),
        color_range=_clean(video.get("color_range")),
        rotation=_rotation(video),
        hdr=is_hdr(color_trc, pix_fmt),
        source_size=source_path.stat().st_size if exists else 0,
        source_mtime=int(source_path.stat().st_mtime) if exists else 0,
    )


def probe_first_frame_dimensions(
    ffprobe: Path,
    path: Path,
    logger: Logger,
) -> tuple[int, int]:
    command = [
        str(ffprobe),
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height",
        "-of",
        "csv=p=0",
        str(path),
    ]
    try:
        result = run_command(command, logger=logger)
    except CommandError as exc:
        raise ValidationError(
            f"Could not read frame dimensions: {path}",
            hint=exc.stderr_tail or str(exc),
        ) from exc
    for line in result.stdout.splitlines():
        parts = [part.strip() for part in line.split(",")]
        if len(parts) >= 2:
            try:
                return int(parts[0]), int(parts[1])
            except ValueError:
                continue
    raise ValidationError(f"Could not parse frame dimensions: {path}")


def probe_media(ffprobe: Path, source: Path, logger: Logger) -> MediaInfo:
    source = Path(source)
    command = [
        str(ffprobe),
        "-v",
        "error",
        "-print_format",
        "json",
        "-show_format",
        "-show_streams",
        "-show_chapters",
        str(source),
    ]
    try:
        result = run_command(command, logger=logger)
    except CommandError as exc:
        raise ValidationError(
            f"ffprobe failed for: {source}",
            hint=exc.stderr_tail or str(exc),
        ) from exc
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise ValidationError(
            f"ffprobe returned invalid JSON for: {source}",
            hint=str(exc),
        ) from exc
    return media_info_from_json(source, data)
