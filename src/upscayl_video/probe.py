"""Media metadata dataclasses shared by probing and pipeline stages."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


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
