"""Media metadata parsing and probing."""

from __future__ import annotations

import json
import math
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Mapping

from .errors import CommandError, ValidationError
from .util import Logger, parse_time, run_command


@dataclass(frozen=True)
class StreamInfo:
    index: int
    codec_name: str
    channels: int | None = None
    bit_rate: int | None = None
    language: str | None = None
    title: str | None = None
    duration: float | None = None


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
    nb_frames: int | None = None
    sample_aspect_ratio: str | None = None

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


def _tag_duration(value: object) -> float | None:
    if not value:
        return None
    try:
        return parse_time(str(value))
    except ValidationError:
        return None


def _stream_info(stream: Mapping[str, Any]) -> StreamInfo:
    tags = stream.get("tags") or {}
    duration = _as_float(stream.get("duration"), 0.0) or _tag_duration(tags.get("DURATION"))
    return StreamInfo(
        index=_as_int(stream.get("index")),
        codec_name=str(stream.get("codec_name") or "unknown"),
        channels=_as_int(stream.get("channels")) if stream.get("channels") is not None else None,
        bit_rate=_as_int(stream.get("bit_rate")) if stream.get("bit_rate") is not None else None,
        language=tags.get("language"),
        title=tags.get("title"),
        duration=duration,
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
    fps_num, fps_den = normalize_fps(
        video.get("avg_frame_rate"),
        video.get("r_frame_rate"),
    )
    packet_count = _as_int(video.get("nb_read_packets") or video.get("nb_frames"))
    # Prefer the video stream duration. If it is absent (common in Matroska),
    # derive it from the packet count; format duration may include a longer
    # audio track and would produce a wrong frame count.
    duration = _as_float(video.get("duration"), 0.0)
    if not duration and packet_count and fps_den:
        duration = packet_count * fps_den / fps_num
    if not duration:
        duration = _as_float(format_info.get("duration"), 0.0)
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

    width = _as_int(video.get("width"))
    height = _as_int(video.get("height"))
    if width <= 0 or height <= 0:
        raise ValidationError(f"Invalid video dimensions in: {source}")
    return MediaInfo(
        source=source_path,
        duration=duration,
        fps_num=fps_num,
        fps_den=fps_den,
        width=width,
        height=height,
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
        nb_frames=packet_count or None,
        sample_aspect_ratio=_clean(video.get("sample_aspect_ratio")),
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


def _last_video_end(
    ffprobe: Path,
    source: Path,
    format_duration: float,
    logger: Logger,
) -> float | None:
    if format_duration <= 0:
        return None
    start = max(0.0, format_duration - 2.0)
    command = [
        str(ffprobe),
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "packet=pts_time,duration_time",
        "-of",
        "csv=p=0",
        "-read_intervals",
        f"{start:.3f}%+2.0",
        str(source),
    ]
    try:
        result = run_command(command, logger=logger, check=False)
    except CommandError:
        return None
    if result.returncode != 0:
        return None
    last_end: float | None = None
    for line in result.stdout.splitlines():
        parts = [part.strip() for part in line.split(",")]
        if not parts or not parts[0]:
            continue
        try:
            pts = float(parts[0])
        except ValueError:
            continue
        duration = 0.0
        if len(parts) > 1:
            try:
                duration = float(parts[1])
            except ValueError:
                duration = 0.0
        end = pts + duration
        # Packets are emitted in decode order. With B-frames the last line is
        # not the last presentation time, so track the maximum end instead.
        if last_end is None or end > last_end:
            last_end = end
    return last_end


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
        "-count_packets",
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
    info = media_info_from_json(source, data)
    video = next(
        (
            stream
            for stream in (data.get("streams") or [])
            if stream.get("codec_type") == "video"
        ),
        None,
    )
    packet_count = 0
    if video is not None:
        packet_count = _as_int(
            video.get("nb_read_packets") or video.get("nb_frames")
        )
    if (
        video is not None
        and not _as_float(video.get("duration"), 0.0)
        and not packet_count
    ):
        format_duration = _as_float((data.get("format") or {}).get("duration"), 0.0)
        end = _last_video_end(ffprobe, source, format_duration, logger)
        if end and end > 0:
            info = replace(info, duration=end)
    return info
