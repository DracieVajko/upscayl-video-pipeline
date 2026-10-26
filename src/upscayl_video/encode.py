"""Output presets, quality mapping, and encoder selection."""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass, replace
from pathlib import Path

from .errors import DependencyError, ValidationError
from .probe import MediaInfo
from .util import Logger


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
    "mov-prores": Preset("mov-prores", "mov", "mov", "prores", "pcm", "auto"),
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


@dataclass(frozen=True)
class AudioStreamPlan:
    source_index: int
    mode: str


@dataclass(frozen=True)
class AudioPlan:
    streams: tuple[AudioStreamPlan, ...]
    enabled: bool


@dataclass(frozen=True)
class SubtitleStreamPlan:
    source_index: int
    mode: str


@dataclass(frozen=True)
class SubtitlePlan:
    streams: tuple[SubtitleStreamPlan, ...]
    dropped: tuple[int, ...]


_MP4_AUDIO = {"aac", "mp3", "ac3", "eac3", "alac"}
_MOV_AUDIO = {"aac", "mp3", "ac3", "eac3", "alac"}
_TEXT_SUBTITLES = {"subrip", "ass", "ssa", "webvtt", "mov_text", "text"}
_IMAGE_SUBTITLES = {
    "hdmv_pgs_subtitle",
    "dvd_subtitle",
    "dvb_subtitle",
    "xsub",
}


def _audio_compatible(container: str, codec: str) -> bool:
    name = codec.lower()
    if container == "mkv":
        return True
    if container == "mp4":
        return name in _MP4_AUDIO
    if container == "mov":
        return name in _MOV_AUDIO or name.startswith("pcm_")
    return False


def _subtitle_compatible(container: str, codec: str) -> bool:
    name = codec.lower()
    if container == "mkv":
        return True
    if container in {"mp4", "mov"}:
        return name == "mov_text"
    return False


def _is_image_subtitle(codec: str) -> bool:
    return codec.lower() in _IMAGE_SUBTITLES


def _is_text_subtitle(codec: str) -> bool:
    return codec.lower() in _TEXT_SUBTITLES


def plan_audio(
    media: MediaInfo,
    preset: Preset,
    mode: str,
    bitrate: int,
    all_audio: bool,
) -> AudioPlan:
    requested = str(mode).strip().lower()
    if requested not in {"auto", "copy", "aac", "pcm", "none"}:
        raise ValidationError(f"Unknown audio mode: {mode}")
    if bitrate <= 0:
        raise ValidationError("Audio bitrate must be greater than zero")
    if not media.audio or requested == "none":
        return AudioPlan((), False)

    selected = media.audio if all_audio else media.audio[:1]
    if requested == "auto" and preset.default_audio in {"copy", "aac", "pcm"}:
        requested = preset.default_audio

    if requested == "pcm":
        if preset.container == "mp4":
            raise ValidationError(
                "PCM audio is not supported in MP4.",
                hint="Use --preset mkv-hevc or --audio aac.",
            )
        return AudioPlan(
            tuple(AudioStreamPlan(stream.index, "pcm") for stream in selected),
            True,
        )

    if requested == "copy":
        bad = [
            stream.codec_name
            for stream in selected
            if not _audio_compatible(preset.container, stream.codec_name)
        ]
        if bad:
            raise ValidationError(
                "Audio codec cannot be copied into "
                f"{preset.container}: {', '.join(sorted(set(bad)))}",
                hint="Use --audio aac or --preset mkv-hevc.",
            )
        return AudioPlan(
            tuple(AudioStreamPlan(stream.index, "copy") for stream in selected),
            True,
        )

    if requested == "aac":
        return AudioPlan(
            tuple(AudioStreamPlan(stream.index, "aac") for stream in selected),
            True,
        )

    # auto: per-stream copy when possible, otherwise AAC.
    return AudioPlan(
        tuple(
            AudioStreamPlan(
                stream.index,
                "copy" if _audio_compatible(preset.container, stream.codec_name) else "aac",
            )
            for stream in selected
        ),
        True,
    )


def plan_subtitles(
    media: MediaInfo,
    preset: Preset,
    mode: str,
    logger: Logger,
) -> SubtitlePlan:
    requested = str(mode).strip().lower()
    if requested not in {"auto", "copy", "convert", "none"}:
        raise ValidationError(f"Unknown subtitle mode: {mode}")
    if not media.subtitles or requested == "none":
        return SubtitlePlan((), ())

    if requested == "copy":
        bad = [
            stream.codec_name
            for stream in media.subtitles
            if not _subtitle_compatible(preset.container, stream.codec_name)
        ]
        if bad:
            raise ValidationError(
                "Subtitle codec cannot be copied into "
                f"{preset.container}: {', '.join(sorted(set(bad)))}",
                hint="Use --subs convert or --preset mkv-hevc.",
            )
        return SubtitlePlan(
            tuple(
                SubtitleStreamPlan(stream.index, "copy")
                for stream in media.subtitles
            ),
            (),
        )

    if requested == "convert":
        image = [stream.index for stream in media.subtitles if _is_image_subtitle(stream.codec_name)]
        if image:
            raise ValidationError(
                "Image subtitles cannot be converted to mov_text.",
                hint="Use --preset mkv-hevc to keep them.",
            )
        return SubtitlePlan(
            tuple(
                SubtitleStreamPlan(stream.index, "mov_text")
                for stream in media.subtitles
            ),
            (),
        )

    if preset.container == "mkv":
        return SubtitlePlan(
            tuple(
                SubtitleStreamPlan(stream.index, "copy")
                for stream in media.subtitles
            ),
            (),
        )

    plans: list[SubtitleStreamPlan] = []
    dropped: list[int] = []
    for stream in media.subtitles:
        if _is_image_subtitle(stream.codec_name):
            dropped.append(stream.index)
            continue
        if _is_text_subtitle(stream.codec_name):
            plans.append(SubtitleStreamPlan(stream.index, "mov_text"))
            continue
        dropped.append(stream.index)
    if dropped:
        logger.warn(
            "Dropped subtitle stream(s) "
            + ", ".join(str(index) for index in dropped)
            + f" that cannot be stored in {preset.container}; use mkv-hevc to keep them."
        )
    return SubtitlePlan(tuple(plans), tuple(dropped))
