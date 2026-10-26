"""Output presets, quality mapping, and encoder selection."""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass, replace
from pathlib import Path

from .errors import DependencyError, OutputValidationError, ValidationError
from .frames import FrameSet
from .job import Job
from .probe import MediaInfo, probe_media
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
        # Matroska supports text and image subtitles, but not mov_text.
        return name != "mov_text"
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


def _even(value: int) -> int:
    return value if value % 2 == 0 else value + 1


def output_dimensions(
    frame_width: int,
    frame_height: int,
    target_height: int | None,
    allow_huge: bool,
) -> tuple[int, int]:
    if target_height is not None:
        target_height = max(2, _even(target_height))
        if target_height > frame_height:
            raise ValidationError(
                f"--target-height ({target_height}) exceeds the upscaled height ({frame_height})"
            )
        output_height = target_height
        output_width = _even(max(2, int(round(frame_width * target_height / frame_height))))
    else:
        output_width = frame_width
        output_height = frame_height
    if not allow_huge:
        if output_width > 8192 or output_height > 8192:
            raise ValidationError(
                "Output exceeds 8192 px on a side; use --allow-huge only if you really need it"
            )
        if output_width * output_height > 40_000_000:
            raise ValidationError(
                "Output exceeds 40 megapixels; use --allow-huge only if you really need it"
            )
    return output_width, output_height


def _color_value(job: Job, media_value: str | None, key: str) -> str | None:
    value = job.get(key) or media_value
    if value is None:
        return None
    text = str(value).strip()
    if not text or text.lower() == "unknown":
        return None
    return text


def build_assemble_command(
    job: Job,
    frame_set: FrameSet,
    media: MediaInfo,
    preset: Preset,
    encoder: EncoderChoice,
    audio_plan: AudioPlan,
    subtitle_plan: SubtitlePlan,
    options: EncodeOptions,
    output: Path,
    *,
    frame_width: int,
    frame_height: int,
) -> list[str]:
    quality_value = resolve_quality(preset, options.quality, options.crf)
    encoder = apply_quality(encoder, options.quality)
    output_dimensions(
        frame_width,
        frame_height,
        options.target_height,
        options.allow_huge,
    )

    has_source_input = bool(
        audio_plan.enabled or subtitle_plan.streams or media.chapters > 0
    )
    fps = job.get("fps") or (media.fps_rational if media.fps_den else "30/1")
    pattern = f"frame_%08d.{frame_set.extension}"

    args: list[str] = [
        "ffmpeg",
        "-hide_banner",
        "-nostdin",
        "-y",
        "-benchmark",
        "-framerate",
        fps,
        "-start_number",
        str(frame_set.first_index),
        "-i",
        str(frame_set.directory / pattern),
    ]
    if has_source_input:
        range_start = float(job.get("range_start") or 0.0)
        if range_start > 0:
            args.extend(["-ss", f"{range_start:.6f}"])
        args.extend(["-i", str(job.source_path)])

    args.extend(["-map", "0:v:0"])
    if audio_plan.enabled:
        for stream in audio_plan.streams:
            args.extend(["-map", f"1:{stream.source_index}"])
        for index, stream in enumerate(audio_plan.streams):
            codec = {"copy": "copy", "aac": "aac", "pcm": "pcm_s24le"}[stream.mode]
            args.extend([f"-c:a:{index}", codec])
            if stream.mode == "aac":
                args.extend([f"-b:a:{index}", f"{options.audio_bitrate}k"])
    else:
        args.append("-an")

    if subtitle_plan.streams:
        for stream in subtitle_plan.streams:
            args.extend(["-map", f"1:{stream.source_index}"])
        for index, stream in enumerate(subtitle_plan.streams):
            args.extend([f"-c:s:{index}", stream.mode])

    if media.chapters > 0:
        args.extend(["-map_chapters", "1"])

    args.extend(video_codec_args(encoder, quality_value, ten_bit=options.ten_bit))

    filters: list[str] = []
    color_range = _color_value(job, media.color_range, "color_range")
    if (color_range or "").lower() == "pc":
        filters.append("scale=in_range=pc:out_range=tv")
        color_range = "tv"
    if options.target_height is not None:
        filters.append(f"scale=-2:{options.target_height}:flags=lanczos")
    if filters:
        args.extend(["-vf", ",".join(filters)])

    for key, flag in (
        ("color_primaries", "-color_primaries"),
        ("color_trc", "-color_trc"),
        ("colorspace", "-colorspace"),
    ):
        value = _color_value(job, getattr(media, key), key)
        if value:
            args.extend([flag, value])
    if color_range:
        args.extend(["-color_range", color_range])

    args.extend(["-metadata:s:v:0", "rotate=0"])
    if has_source_input:
        args.extend(["-map_metadata", "1"])
    if preset.container in {"mp4", "mov"}:
        args.extend(["-movflags", "+faststart"])
    if preset.codec == "hevc" and preset.container in {"mp4", "mov"}:
        args.extend(["-tag:v", "hvc1"])
    if audio_plan.enabled or subtitle_plan.streams:
        # Use an explicit output duration instead of -shortest. Audio tracks
        # are frequently slightly shorter than the video (codec padding), and
        # -shortest would silently drop the last video frames.
        duration_value = float(job.get("duration") or 0.0)
        if duration_value <= 0:
            duration_value = frame_set.count / max(media.fps_decimal, 1.0)
        args.extend(["-t", f"{duration_value:.6f}"])
    args.append(str(output))
    return args


def build_segment_command(
    job: Job,
    frame_set: FrameSet,
    media: MediaInfo,
    preset: Preset,
    encoder: EncoderChoice,
    options: EncodeOptions,
    output: Path,
    *,
    frame_width: int,
    frame_height: int,
) -> list[str]:
    quality_value = resolve_quality(preset, options.quality, options.crf)
    encoder = apply_quality(encoder, options.quality)
    output_dimensions(frame_width, frame_height, options.target_height, options.allow_huge)
    fps = job.get("fps") or (media.fps_rational if media.fps_den else "30/1")
    pattern = f"frame_%08d.{frame_set.extension}"
    args = [
        "ffmpeg", "-hide_banner", "-nostdin", "-y", "-benchmark",
        "-framerate", fps, "-start_number", str(frame_set.first_index),
        "-i", str(frame_set.directory / pattern),
        "-map", "0:v:0", "-an", "-sn", "-dn",
        "-frames:v", str(frame_set.count),
    ]
    args.extend(video_codec_args(encoder, quality_value, ten_bit=options.ten_bit))
    filters: list[str] = []
    color_range = _color_value(job, media.color_range, "color_range")
    if (color_range or "").lower() == "pc":
        filters.append("scale=in_range=pc:out_range=tv")
        color_range = "tv"
    if options.target_height is not None:
        filters.append(f"scale=-2:{options.target_height}:flags=lanczos")
    if filters:
        args.extend(["-vf", ",".join(filters)])
    for key, flag in (
        ("color_primaries", "-color_primaries"),
        ("color_trc", "-color_trc"),
        ("colorspace", "-colorspace"),
    ):
        value = _color_value(job, getattr(media, key), key)
        if value:
            args.extend([flag, value])
    if color_range:
        args.extend(["-color_range", color_range])
    args.extend(["-metadata:s:v:0", "rotate=0"])
    if preset.codec == "prores":
        args.extend(["-f", "mov"])
    else:
        args.extend(["-muxdelay", "0", "-muxpreload", "0", "-f", "mpegts"])
    args.append(str(output))
    return args


def build_mux_command(
    job: Job,
    media: MediaInfo,
    preset: Preset,
    audio_plan: AudioPlan,
    subtitle_plan: SubtitlePlan,
    options: EncodeOptions,
    concat_video: Path,
    output: Path,
    duration: float,
) -> list[str]:
    has_source = bool(
        audio_plan.enabled or subtitle_plan.streams or media.chapters > 0
    )
    args = ["ffmpeg", "-hide_banner", "-nostdin", "-y", "-benchmark"]
    args.extend(["-i", str(concat_video)])
    if has_source:
        range_start = float(job.get("range_start") or 0.0)
        if range_start > 0:
            args.extend(["-ss", f"{range_start:.6f}"])
        args.extend(["-i", str(job.source_path)])
    args.extend(["-map", "0:v:0"])
    if audio_plan.enabled:
        for stream in audio_plan.streams:
            args.extend(["-map", f"1:{stream.source_index}"])
        for index, stream in enumerate(audio_plan.streams):
            codec = {"copy": "copy", "aac": "aac", "pcm": "pcm_s24le"}[stream.mode]
            args.extend([f"-c:a:{index}", codec])
            if stream.mode == "aac":
                args.extend([f"-b:a:{index}", f"{options.audio_bitrate}k"])
    else:
        args.append("-an")
    if subtitle_plan.streams:
        for stream in subtitle_plan.streams:
            args.extend(["-map", f"1:{stream.source_index}"])
        for index, stream in enumerate(subtitle_plan.streams):
            args.extend([f"-c:s:{index}", stream.mode])
    if media.chapters > 0:
        args.extend(["-map_chapters", "1"])
    args.extend(["-c:v", "copy"])
    args.extend(["-t", f"{duration:.6f}"])
    if has_source:
        args.extend(["-map_metadata", "1"])
    args.extend(["-metadata:s:v:0", "rotate=0"])
    if preset.container in {"mp4", "mov"}:
        args.extend(["-movflags", "+faststart"])
    if preset.codec == "hevc" and preset.container in {"mp4", "mov"}:
        args.extend(["-tag:v", "hvc1"])
    args.append(str(output))
    return args


def validate_output(
    ffprobe: Path,
    output: Path,
    job: Job,
    media: MediaInfo,
    options: EncodeOptions,
    expected_width: int,
    expected_height: int,
    expected_audio: bool,
    expected_subs: int,
    logger: Logger,
) -> None:
    try:
        info = probe_media(ffprobe, output, logger)
    except ValidationError as exc:
        raise OutputValidationError(
            f"Output is not a readable video: {output}",
            hint=str(exc),
        ) from exc

    problems: list[str] = []
    if (info.width, info.height) != (expected_width, expected_height):
        problems.append(
            f"dimensions {info.width}x{info.height}, expected {expected_width}x{expected_height}"
        )
    expected_duration = float(job.get("duration") or media.duration or 0.0)
    tolerance = max(0.1, 1.0 / max(info.fps_decimal, 1.0))
    if abs(info.duration - expected_duration) > tolerance:
        problems.append(
            f"duration {info.duration:.3f}s, expected {expected_duration:.3f}s"
        )
    expected_fps = float(job.get("fps_decimal") or media.fps_decimal or 0.0)
    if expected_fps and abs(info.fps_decimal - expected_fps) > 0.02:
        problems.append(f"fps {info.fps_decimal:.3f}, expected {expected_fps:.3f}")
    if bool(info.audio) != expected_audio:
        problems.append(
            f"audio streams {len(info.audio)}, expected {'at least one' if expected_audio else 'none'}"
        )
    if len(info.subtitles) != expected_subs:
        problems.append(
            f"subtitle streams {len(info.subtitles)}, expected {expected_subs}"
        )
    preset = resolve_preset(options.preset)
    if preset.codec == "prores":
        expected_pix_fmt = "yuv422p10le"
    elif options.ten_bit:
        expected_pix_fmt = "yuv420p10le"
    else:
        expected_pix_fmt = "yuv420p"
    if info.pix_fmt != expected_pix_fmt:
        problems.append(f"pixel format {info.pix_fmt}, expected {expected_pix_fmt}")
    if problems:
        raise OutputValidationError(
            "Output validation failed: " + "; ".join(problems)
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
                "Image subtitles cannot be converted to a text format.",
                hint="Use --preset mkv-hevc to keep them.",
            )
        text_mode = "subrip" if preset.container == "mkv" else "mov_text"
        return SubtitlePlan(
            tuple(
                SubtitleStreamPlan(stream.index, text_mode)
                for stream in media.subtitles
            ),
            (),
        )

    if preset.container == "mkv":
        return SubtitlePlan(
            tuple(
                SubtitleStreamPlan(
                    stream.index,
                    "subrip" if stream.codec_name.lower() == "mov_text" else "copy",
                )
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
