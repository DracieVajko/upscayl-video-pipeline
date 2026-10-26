"""Output presets, quality mapping, and encoder selection."""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass, replace
from pathlib import Path

from .errors import DependencyError, ValidationError


@dataclass(frozen=True)
class Preset:
    name: str
    container: str
    extension: str
    codec: str
    default_audio: str
    default_subs: str


PRESETS: dict[str, Preset] = {
    "mp4-h264": Preset("mp4-h264", "mp4", "mp4", "h264", "auto", "auto"),
    "mp4-hevc": Preset("mp4-hevc", "mp4", "mp4", "hevc", "auto", "auto"),
    "mkv-hevc": Preset("mkv-hevc", "mkv", "mkv", "hevc", "copy", "copy"),
    "mov-prores": Preset("mov-prores", "mov", "mov", "prores", "pcm", "copy"),
}


@dataclass(frozen=True)
class EncodeOptions:
    preset: str = "mp4-h264"
    encoder: str = "auto"
    quality: str = "balanced"
    crf: int | None = None
    audio: str | None = None
    audio_bitrate: int = 192
    all_audio: bool = False
    subs: str | None = None
    ten_bit: bool = False
    target_height: int | None = None
    cleanup: bool = False
    output: Path | None = None
    upscaled_dir: Path | None = None
    pick: str = "error"
    verify_frames: bool = False
    allow_huge: bool = False
    force: bool = False
    keep_chunks: bool = False


@dataclass(frozen=True)
class EncoderChoice:
    family: str
    video_codec: str
    quality_args: tuple[str, ...] = ()


_QUALITY_LEVELS = {"fast", "balanced", "quality"}
_AVAILABLE_CACHE: dict[tuple[str, float], set[str]] = {}


def resolve_preset(name: str) -> Preset:
    key = str(name).strip().lower()
    preset = PRESETS.get(key)
    if preset is None:
        raise ValidationError(
            f"Unknown preset: {name}",
            hint="Choose one of: " + ", ".join(sorted(PRESETS)),
        )
    return preset


def resolve_quality(preset: Preset, quality: str, crf: int | None) -> int:
    level = str(quality).strip().lower()
    if level not in _QUALITY_LEVELS:
        raise ValidationError(f"Unknown quality level: {quality}")
    if preset.codec == "prores":
        if crf is not None:
            raise ValidationError("ProRes does not support --crf; use --quality instead")
        return 0
    if crf is not None:
        value = int(crf)
        if value < 0 or value > 51:
            raise ValidationError("--crf must be between 0 and 51 for H.264/HEVC")
        return value
    if preset.codec == "h264":
        return {"fast": 22, "balanced": 20, "quality": 18}[level]
    return {"fast": 24, "balanced": 22, "quality": 20}[level]


def parse_available_encoders(ffmpeg: Path) -> set[str]:
    ffmpeg_path = Path(ffmpeg)
    try:
        resolved = ffmpeg_path.resolve()
        mtime = resolved.stat().st_mtime
    except OSError:
        resolved = ffmpeg_path
        mtime = 0.0
    key = (str(resolved), mtime)
    cached = _AVAILABLE_CACHE.get(key)
    if cached is not None:
        return cached
    try:
        result = subprocess.run(
            [str(ffmpeg_path), "-hide_banner", "-encoders"],
            text=True,
            encoding="utf-8",
            errors="replace",
            stdin=subprocess.DEVNULL,
            capture_output=True,
            check=False,
        )
    except OSError:
        _AVAILABLE_CACHE[key] = set()
        return set()
    if result.returncode != 0:
        _AVAILABLE_CACHE[key] = set()
        return set()
    names: set[str] = set()
    for line in result.stdout.splitlines():
        match = re.match(r"^\s*[A-Z.]{6}\s+(\S+)", line)
        if match:
            names.add(match.group(1))
    _AVAILABLE_CACHE[key] = names
    return names


def apply_quality(choice: EncoderChoice, quality: str) -> EncoderChoice:
    level = str(quality).strip().lower()
    if level not in _QUALITY_LEVELS:
        raise ValidationError(f"Unknown quality level: {quality}")
    if choice.video_codec == "prores_ks":
        profile = {"fast": "1", "balanced": "2", "quality": "3"}[level]
        return replace(choice, quality_args=(profile,))
    if choice.family == "nvidia":
        preset = {"fast": "p5", "balanced": "p6", "quality": "p7"}[level]
        args = ["-preset", preset, "-tune", "hq", "-rc", "vbr"]
        if level == "quality":
            args += ["-multipass", "fullres", "-spatial_aq", "1", "-aq-strength", "12"]
        return replace(choice, quality_args=tuple(args))
    if choice.family == "amd":
        return replace(choice, quality_args=("-quality", "quality", "-rc", "cqp"))
    if choice.video_codec == "libx264":
        preset = {"fast": "veryfast", "balanced": "medium", "quality": "slow"}[level]
        return replace(choice, quality_args=("-preset", preset))
    if choice.video_codec == "libx265":
        preset = {"fast": "fast", "balanced": "medium", "quality": "slow"}[level]
        return replace(choice, quality_args=("-preset", preset))
    return choice


def video_codec_args(
    choice: EncoderChoice,
    quality_value: int,
    *,
    ten_bit: bool,
) -> list[str]:
    if choice.video_codec == "prores_ks":
        if ten_bit:
            raise ValidationError("--10bit is not valid with ProRes; ProRes is already 10-bit")
        profile = choice.quality_args[0] if choice.quality_args else "3"
        return [
            "-c:v",
            "prores_ks",
            "-profile:v",
            str(profile),
            "-vendor",
            "apl0",
            "-pix_fmt",
            "yuv422p10le",
        ]

    h264 = choice.video_codec in {"h264_nvenc", "h264_amf", "libx264"}
    hevc = choice.video_codec in {"hevc_nvenc", "hevc_amf", "libx265"}
    if ten_bit and h264:
        raise ValidationError("--10bit is only valid for HEVC output")

    args = ["-c:v", choice.video_codec]
    args.extend(choice.quality_args)
    if choice.family == "nvidia":
        if "-preset" not in args:
            args += ["-preset", "p6", "-tune", "hq", "-rc", "vbr"]
        args += ["-cq", str(quality_value), "-b:v", "0"]
    elif choice.family == "amd":
        if "-quality" not in args:
            args += ["-quality", "quality", "-rc", "cqp"]
        args += ["-qp_i", str(quality_value), "-qp_p", str(quality_value)]
    else:
        if choice.video_codec in {"libx264", "libx265"}:
            if "-preset" not in args:
                args += ["-preset", "medium"]
            args += ["-crf", str(quality_value)]
    args += ["-pix_fmt", "yuv420p10le" if ten_bit and hevc else "yuv420p"]
    return args


def encoder_candidates(preset: Preset, requested: str, ffmpeg: Path) -> list[EncoderChoice]:
    mode = str(requested).strip().lower()
    if mode not in {"auto", "nvidia", "amd", "cpu"}:
        raise ValidationError(f"Unknown encoder: {requested}")
    available = parse_available_encoders(ffmpeg)

    codecs = {
        "h264": {"nvidia": "h264_nvenc", "amd": "h264_amf", "cpu": "libx264"},
        "hevc": {"nvidia": "hevc_nvenc", "amd": "hevc_amf", "cpu": "libx265"},
        "prores": {"nvidia": None, "amd": None, "cpu": "prores_ks"},
    }[preset.codec]

    order = ("nvidia", "amd", "cpu") if mode == "auto" else (mode,)
    candidates: list[EncoderChoice] = []
    for family in order:
        codec = codecs[family]
        if codec and codec in available:
            candidates.append(apply_quality(EncoderChoice(family, codec), "balanced"))
    if not candidates:
        if mode == "auto":
            raise DependencyError(
                f"No usable encoder found for {preset.name}",
                hint="Install FFmpeg with the required encoders or use --encoder cpu.",
            )
        codec = codecs[mode]
        raise DependencyError(
            f"Encoder not available: {codec or mode}",
            hint="Use --encoder auto or cpu.",
        )
    return candidates
