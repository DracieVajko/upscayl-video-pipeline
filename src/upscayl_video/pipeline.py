"""Pipeline orchestration for split, assemble, status, and clean."""

from __future__ import annotations

import dataclasses
import glob
import os
import shutil
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
from typing import Sequence

from .config import Config
from .disk import check_estimate, estimate_disk, free_bytes, sample_frame_bytes
from .chunking import concat_segments, plan_chunks
from .encode import (
    EncodeOptions,
    build_assemble_command,
    build_mux_command,
    build_segment_command,
    encoder_candidates,
    output_dimensions,
    plan_audio,
    plan_subtitles,
    resolve_preset,
    validate_output,
)
from .errors import (
    CommandError,
    DiskSpaceError,
    EncodeError,
    PipelineError,
    UsageError,
    ValidationError,
)
from .frames import (
    build_sequence,
    build_split_command,
    count_contiguous_frames,
    extract_frames,
    frame_pattern,
    scan_frames,
    validate_frame_set,
)
from .job import Job, find_jobs
from .probe import MediaInfo, parse_rational, probe_first_frame_dimensions, probe_media
from .progress import Progress
from .upscayl import (
    detect_vram_mb,
    discover_upscayl,
    list_models,
    resolve_batch_size,
    resolve_icd,
    resolve_tile,
    upscale_frames,
)
from .util import (
    Logger,
    ensure_within,
    format_duration,
    human_bytes,
    parse_time,
    run_command,
)

_VIDEO_EXTENSIONS = {
    ".mp4", ".mkv", ".mov", ".avi", ".webm", ".m4v", ".ts", ".m2ts",
    ".wmv", ".flv", ".mpg", ".mpeg", ".ogv",
}


@dataclass(frozen=True)
class UpscaleOptions:
    model: str
    scale: int = 2
    gpu: int = 0
    tile: str = "auto"
    batch_size: int = 0
    threads: str = "1:2:2"
    icd: str | None = None
    upscayl_bin: Path | None = None
    models_dir: Path | None = None
    upscaled_dir: Path | None = None
    retry: int = 1
    force: bool = False


@dataclass(frozen=True)
class RunOptions:
    split: SplitOptions
    upscale: UpscaleOptions
    encode: EncodeOptions
    cleanup: bool = False
    stop_on_error: bool = False
    chunk_seconds: str = "auto"


@dataclass(frozen=True)
class RunResult:
    input_path: Path
    job: Job | None
    output: Path | None
    error: str | None


@dataclass(frozen=True)
class SplitOptions:
    fps: str | None
    start: str | None
    end: str | None
    format: str
    jpeg_quality: int
    png_compression: int
    denoise: str
    tonemap: bool
    decode: str
    scale: int | None
    target_height: int | None
    model: str
    verify_frames: bool
    recursive: bool
    force: bool


def _is_video(path: Path) -> bool:
    return path.suffix.lower() in _VIDEO_EXTENSIONS


def _skip_path(path: Path, work_dir: Path) -> bool:
    if path.name.startswith("."):
        return True
    if path.stem.lower().endswith("_upscaled"):
        return True
    try:
        path.resolve().relative_to(work_dir.resolve())
        return True
    except ValueError:
        return False


def resolve_inputs(
    args: Sequence[str],
    config: Config,
    *,
    recursive: bool,
) -> list[Path]:
    if not args:
        default_input = Path(config.tool_dir) / "input"
        if default_input.is_dir():
            args = [str(default_input)]
        else:
            raise UsageError(
                "No input videos given.",
                hint="Pass files/folders, or create an input/ folder next to the tool.",
            )

    found: list[Path] = []
    for raw in args:
        text = str(raw)
        path = Path(text).expanduser()
        if any(char in text for char in "*?[]"):
            matches = glob.glob(text, recursive=recursive)
            candidates = [Path(match) for match in matches]
        elif path.is_dir():
            candidates = list(path.rglob("*") if recursive else path.iterdir())
        elif path.is_file():
            candidates = [path]
        else:
            candidates = []
        for candidate in candidates:
            if not candidate.is_file():
                continue
            if not _is_video(candidate):
                continue
            if _skip_path(candidate, config.work_dir):
                continue
            found.append(candidate.resolve())

    unique = sorted(set(found), key=lambda item: item.name.lower())
    if not unique:
        raise UsageError(
            "No supported video files found.",
            hint="Supported: " + ", ".join(sorted(_VIDEO_EXTENSIONS)),
        )
    return unique


def _parse_fps_override(value: str) -> tuple[int, int]:
    text = str(value).strip()
    if "/" in text:
        numerator, denominator = parse_rational(text)
        if numerator <= 0 or denominator <= 0:
            raise ValidationError(f"Invalid --fps value: {value}")
        divisor = Fraction(numerator, denominator)
        return divisor.numerator, divisor.denominator
    try:
        fraction = Fraction(text).limit_denominator(1_000_000)
    except (ValueError, ZeroDivisionError) as exc:
        raise ValidationError(f"Invalid --fps value: {value}") from exc
    if fraction.numerator <= 0 or fraction.denominator <= 0:
        raise ValidationError(f"Invalid --fps value: {value}")
    return fraction.numerator, fraction.denominator


def _has_frames(job: Job) -> bool:
    return any(
        path.is_file() and path.stat().st_size > 0
        for paths in scan_frames(job.frames_dir, recursive=False).values()
        for path in paths
    )


def _clear_split_outputs(job: Job) -> None:
    for directory in (job.frames_dir, job.upscaled_dir, job.sequence_dir):
        if directory.exists():
            shutil.rmtree(directory)
    for marker in job.path.glob(".done_*"):
        if marker.is_file():
            marker.unlink()
    job.set("frame_count", 0)
    job.set("upscaled_count", 0)
    job.save()


def _settings_differences(job: Job, media: MediaInfo, start: float, end: float | None, options: SplitOptions) -> list[str]:
    expected = {
        "frame_format": options.format.lower(),
        "fps": media.fps_rational,
        "range_start": f"{start:.3f}",
        "range_end": "" if end is None else f"{end:.3f}",
        "denoise": options.denoise,
        "tonemap": "1" if options.tonemap else "0",
        "png_compression": str(options.png_compression),
        "jpeg_quality": str(options.jpeg_quality),
    }
    differences: list[str] = []
    for key, value in expected.items():
        existing = job.get(key)
        if existing is None:
            continue
        if key in {"range_start", "range_end"}:
            try:
                same = abs(float(existing or 0) - float(value or 0)) < 0.001
            except ValueError:
                same = existing == value
        else:
            same = existing == value
        if not same:
            differences.append(f"{key}: {existing!r} -> {value!r}")
    return differences


def _resolve_scale(media: MediaInfo, options: SplitOptions, job: Job, config: Config) -> tuple[int, int | None]:
    target = options.target_height
    if target is None:
        raw_target = job.get("target_height")
        target = int(raw_target) if raw_target not in {None, ""} else None
    if target is not None and target % 2:
        target += 1
    scale = options.scale
    if scale is None:
        raw_scale = job.get("scale")
        scale = int(raw_scale) if raw_scale not in {None, ""} else None

    if target is not None and target <= media.height:
        raise ValidationError(
            f"--target-height ({target}) must be greater than the source height ({media.height})"
        )
    if target is None:
        return (scale or config.default_scale), None
    if scale is not None:
        if media.height * scale < target:
            raise ValidationError(
                f"Scale {scale}x gives {media.height * scale}px, below --target-height {target}"
            )
        return scale, target
    for candidate in (2, 3, 4):
        if media.height * candidate >= target:
            return candidate, target
    raise ValidationError(
        f"--target-height {target} requires more than 4x from {media.height}px"
    )


def run_split(
    inputs: Sequence[Path],
    config: Config,
    options: SplitOptions,
    logger: Logger,
    *,
    dry_run: bool = False,
    assume_yes: bool = False,
) -> list[Job]:
    jobs: list[Job] = []
    for input_path in inputs:
        source = Path(input_path).expanduser().resolve()
        media = probe_media(config.ffprobe, source, logger)
        if media.duration <= 0:
            raise ValidationError(f"Could not determine a positive video duration: {source}")
        if options.fps:
            fps_num, fps_den = _parse_fps_override(options.fps)
            media = dataclasses.replace(media, fps_num=fps_num, fps_den=fps_den)

        start = parse_time(options.start) if options.start else 0.0
        end = parse_time(options.end) if options.end else media.duration
        if end > media.duration + 0.001:
            logger.warn(f"--end {end:.3f}s exceeds source duration; clamping to {media.duration:.3f}s")
            end = media.duration
        if start >= end:
            raise ValidationError(
                f"--start ({start:.3f}s) must be before --end ({end:.3f}s)"
            )
        processed_duration = end - start

        job = Job.create_or_open(config.work_dir, source, logger, create=not dry_run)
        if not dry_run:
            logger.set_log_file(job.logs_dir / "split.log")

        has_frames = _has_frames(job)
        if has_frames and job.source_changed() and not options.force:
            raise ValidationError(
                f"Source changed since the job was created: {source}",
                hint="Use --force to rebuild the job.",
            )
        if has_frames and not options.force:
            differences = _settings_differences(job, media, start, end, options)
            if differences:
                raise ValidationError(
                    "Existing job was split with different settings.",
                    hint="Use --force to re-split. Differences: " + "; ".join(differences),
                )
        if has_frames and options.force:
            if not dry_run:
                if not assume_yes:
                    answer = input(f"Clear existing frames for {job.job_id}? [y/N] ").strip().lower()
                    if answer not in {"y", "yes"}:
                        raise ValidationError("Aborted by user.")
                _clear_split_outputs(job)

        if options.target_height is not None and options.target_height % 2:
            logger.warn(
                f"--target-height {options.target_height} is odd; rounding up to "
                f"{options.target_height + 1}"
            )
            options = dataclasses.replace(
                options, target_height=options.target_height + 1
            )
        scale, target_height = _resolve_scale(media, options, job, config)
        if media.hdr and not options.tonemap:
            raise ValidationError(
                "HDR source detected. Upscayl models are 8-bit SDR.",
                hint="Re-run with --tonemap to convert HDR to SDR BT.709.",
            )
        if not media.hdr and any(bit in media.pix_fmt.lower() for bit in ("10", "12", "16")):
            logger.warn(
                "10-bit SDR source: frames will be converted to 8-bit RGB for Upscayl."
            )
        if media.sample_aspect_ratio not in {None, "", "0:1", "1:1"}:
            logger.warn(
                f"Anamorphic source detected (SAR {media.sample_aspect_ratio}); "
                "the output uses square pixels and may not preserve display aspect ratio."
            )

        job.update_from_media(media)
        if options.tonemap:
            job.set("color_primaries", "bt709")
            job.set("color_trc", "bt709")
            job.set("colorspace", "bt709")
            job.set("color_range", "tv")
            job.set("hdr", False)
        job.set("duration", f"{processed_duration:.3f}")
        job.set("range_start", f"{start:.3f}")
        job.set("range_end", "" if options.end is None else f"{end:.3f}")
        job.set("scale", scale)
        job.set("target_height", "" if target_height is None else target_height)
        job.set("model", options.model)
        job.set("frame_format", options.format.lower())
        job.set("frame_pattern", frame_pattern(options.format))
        job.set("chunk_seconds", 0)
        job.set("chunk_frames", 0)
        job.set("denoise", options.denoise)
        job.set("decode", options.decode)
        job.set("tonemap", options.tonemap)
        job.set("png_compression", options.png_compression)
        job.set("jpeg_quality", options.jpeg_quality)
        if not dry_run:
            job.save()

        expected_frames = int(round(processed_duration * media.fps_decimal))
        sample_bytes = sample_frame_bytes(
            job.source_path,
            job,
            media,
            config,
            fmt=options.format,
            denoise=options.denoise,
            tonemap=options.tonemap,
            decode=options.decode,
            logger=logger,
            start=start,
            duration=processed_duration,
        )
        estimate = estimate_disk(sample_bytes, expected_frames, scale)
        estimate = dataclasses.replace(estimate, free_bytes=free_bytes(config.work_dir))
        logger.info(
            f"Job {job.job_id}: {format_duration(processed_duration)}, "
            f"{expected_frames} frames, sample {human_bytes(sample_bytes)}, "
            f"estimated {human_bytes(estimate.total_bytes)}, "
            f"free {human_bytes(estimate.free_bytes)}"
        )
        check_estimate(
            estimate,
            min_free_gb=config.min_free_gb,
            max_work_gb=config.max_work_gb,
            logger=logger,
        )
        if dry_run:
            continue

        try:
            count = extract_frames(
                job,
                media,
                config,
                fmt=options.format,
                jpeg_quality=options.jpeg_quality,
                png_compression=options.png_compression,
                denoise=options.denoise,
                tonemap=options.tonemap,
                decode=options.decode,
                start=start,
                end=end,
                verify=options.verify_frames,
                logger=logger,
            )
        except PipelineError as exc:
            job.set("last_error", str(exc)[:500])
            try:
                job.save()
            except OSError:
                pass
            raise
        job.set("frame_count", count)
        job.set("upscaled_count", 0)
        job.set("last_error", "")
        job.save()
        job.mark_done("split")
        jobs.append(job)
    return jobs


def run_upscale(
    jobs: Sequence[Job],
    config: Config,
    options: UpscaleOptions,
    logger: Logger,
    *,
    dry_run: bool = False,
) -> list[Job]:
    effective_config = dataclasses.replace(
        config,
        upscayl_bin=options.upscayl_bin or config.upscayl_bin,
        models_dir=options.models_dir or config.models_dir,
    )
    paths = discover_upscayl(effective_config)
    models = list_models(paths.models_dir)
    names = {model.name for model in models}
    if options.model not in names:
        raise ValidationError(
            f"Upscayl model not found: {options.model}",
            hint="Installed: " + ", ".join(sorted(names)),
        )
    tile = resolve_tile(options.tile, detect_vram_mb())
    icd = resolve_icd(effective_config, options.icd)
    results: list[Job] = []
    for job in jobs:
        if not job.frames_dir.is_dir():
            raise ValidationError(
                f"No frames found for job: {job.job_id}",
                hint="Run split first.",
            )
        frame_count = job.get_int("frame_count")
        if frame_count <= 0:
            frame_count = count_contiguous_frames(
                job.frames_dir,
                job.get("frame_format") or "png",
            )
        if frame_count <= 0:
            raise ValidationError(f"Job has no frames: {job.job_id}")
        output_dir = (
            Path(options.upscaled_dir).expanduser()
            if options.upscaled_dir is not None
            else job.upscaled_dir
        )
        existing = any(
            path.is_file() for path in output_dir.glob("*")
        ) if output_dir.is_dir() else False
        if existing and (
            (job.get("model") and job.get("model") != options.model)
            or (job.get_int("scale") and job.get_int("scale") != options.scale)
        ) and not options.force:
            raise ValidationError(
                "Existing upscaled frames use a different model or scale.",
                hint="Use --force to clear them and upscale again.",
            )
        if existing and options.force and (
            (job.get("model") and job.get("model") != options.model)
            or (job.get_int("scale") and job.get_int("scale") != options.scale)
        ):
            if output_dir.exists():
                shutil.rmtree(output_dir)
            job.clear_stage("upscale")
            job.set("upscaled_count", 0)
        width = job.get_int("width", 1920)
        height = job.get_int("height", 1080)
        batch_size = resolve_batch_size(options.batch_size, width, height)
        if dry_run:
            logger.info(
                f"Would upscale {job.job_id}: {frame_count} frames with "
                f"{options.model} at {options.scale}x, tile {tile}, batch {batch_size}"
            )
            results.append(job)
            continue
        progress = Progress("upscale", frame_count)
        try:
            count = upscale_frames(
                job,
                paths,
                model=options.model,
                scale=options.scale,
                output_dir=output_dir,
                tile=tile,
                batch_size=batch_size,
                gpu=options.gpu,
                icd=icd,
                threads=options.threads,
                retry=options.retry,
                logger=logger,
                progress=progress,
            )
        except PipelineError as exc:
            job.set("last_error", str(exc)[:500])
            try:
                job.save()
            except OSError:
                pass
            raise
        job.set("model", options.model)
        job.set("scale", options.scale)
        job.set("tile", tile)
        job.set("batch_size", batch_size)
        job.set("upscaled_count", count)
        job.set("upscaled_dir", str(output_dir))
        job.set("last_error", "")
        job.save()
        job.mark_done("upscale")
        results.append(job)
    return results


def _prepare_chunk_job(
    source: Path,
    config: Config,
    options: RunOptions,
    chunk_seconds: int,
    logger: Logger,
) -> tuple[Job, MediaInfo, float, float, float]:
    media = probe_media(config.ffprobe, source, logger)
    if media.duration <= 0:
        raise ValidationError(f"Could not determine video duration: {source}")
    if options.split.fps:
        fps_num, fps_den = _parse_fps_override(options.split.fps)
        media = dataclasses.replace(media, fps_num=fps_num, fps_den=fps_den)
    start = parse_time(options.split.start) if options.split.start else 0.0
    end = parse_time(options.split.end) if options.split.end else media.duration
    end = min(end, media.duration)
    if start >= end:
        raise ValidationError("Trim range is empty")
    duration = end - start
    job = Job.create_or_open(config.work_dir, source, logger)
    logger.set_log_file(job.logs_dir / "run.log")
    if media.hdr and not options.split.tonemap:
        raise ValidationError(
            "HDR source detected. Upscayl models are 8-bit SDR.",
            hint="Re-run with --tonemap to convert HDR to SDR BT.709.",
        )
    job.update_from_media(media)
    if options.split.tonemap:
        job.set("color_primaries", "bt709")
        job.set("color_trc", "bt709")
        job.set("colorspace", "bt709")
        job.set("color_range", "tv")
        job.set("hdr", False)
    scale, target = _resolve_scale(media, options.split, job, config)
    fps = media.fps_decimal or 30.0
    total_frames = int(round(duration * fps))
    job.set("duration", f"{duration:.3f}")
    job.set("range_start", f"{start:.3f}")
    job.set("range_end", "" if options.split.end is None else f"{end:.3f}")
    job.set("scale", scale)
    job.set("target_height", "" if target is None else target)
    job.set("model", options.split.model)
    job.set("frame_format", options.split.format)
    job.set("frame_pattern", frame_pattern(options.split.format))
    job.set("denoise", options.split.denoise)
    job.set("decode", options.split.decode)
    job.set("tonemap", options.split.tonemap)
    job.set("frame_count", total_frames)
    job.set("upscaled_count", 0)
    job.set("chunk_seconds", chunk_seconds)
    job.set("chunk_frames", int(round(chunk_seconds * fps)))
    job.save()
    return job, media, start, end, duration


def _run_chunked(
    source: Path,
    config: Config,
    options: RunOptions,
    chunk_seconds: int,
    logger: Logger,
) -> RunResult:
    job, media, start, end, duration = _prepare_chunk_job(
        source, config, options, chunk_seconds, logger
    )
    temp_output: Path | None = None
    try:
        preset = resolve_preset(options.encode.preset)
        paths = discover_upscayl(dataclasses.replace(
            config,
            upscayl_bin=options.upscale.upscayl_bin or config.upscayl_bin,
            models_dir=options.upscale.models_dir or config.models_dir,
        ))
        models = list_models(paths.models_dir)
        if options.upscale.model not in {model.name for model in models}:
            raise ValidationError(f"Upscayl model not found: {options.upscale.model}")
        tile = resolve_tile(options.upscale.tile, detect_vram_mb())
        icd = resolve_icd(config, options.upscale.icd)
        chunks = plan_chunks(duration, media.fps_decimal or 30.0, chunk_seconds)
        if not chunks:
            raise ValidationError("Chunk plan is empty")
        candidates = encoder_candidates(preset, options.encode.encoder, config.ffmpeg)
        audio_mode = options.encode.audio or (
            config.default_audio if config.default_audio != "auto" else preset.default_audio
        )
        subs_mode = options.encode.subs or (
            config.default_subs if config.default_subs != "auto" else preset.default_subs
        )
        audio_plan = plan_audio(
            media, preset, audio_mode, options.encode.audio_bitrate, options.encode.all_audio
        )
        if start > 0 and any(stream.mode == "copy" for stream in audio_plan.streams):
            audio_plan = dataclasses.replace(
                audio_plan,
                streams=tuple(
                    dataclasses.replace(stream, mode="aac")
                    if stream.mode == "copy"
                    else stream
                    for stream in audio_plan.streams
                ),
            )
        subtitle_plan = plan_subtitles(media, preset, subs_mode, logger)
        final_output = _resolve_output_path(
            job, preset.extension, options.encode, multiple_jobs=False
        )
        temp_output = final_output.with_name(
            f"{final_output.stem}.partial{final_output.suffix}"
        )
        final_output.parent.mkdir(parents=True, exist_ok=True)
        progress = Progress("upscale", job.get_int("frame_count"))
        expected_width = expected_height = 0
        segments: list[Path] = []
        for chunk in chunks:
            if free_bytes(config.work_dir) < config.min_free_gb * 1024**3:
                raise DiskSpaceError(
                    "Free space fell below the configured minimum before a chunk."
                )
            extension = "mov" if preset.codec == "prores" else "ts"
            segment = job.chunks_dir / f"chunk_{chunk.index:04d}.{extension}"
            marker = job.path / f".done_chunk_{chunk.index:04d}"
            segments.append(segment)
            if marker.is_file() and segment.is_file() and segment.stat().st_size > 0:
                progress.update(chunk.frame_count)
                continue
            chunk_dir = job.chunks_dir / f"chunk_{chunk.index:04d}"
            if chunk_dir.exists():
                shutil.rmtree(chunk_dir)
            frames_dir = chunk_dir / "frames"
            upscaled_dir = chunk_dir / "upscaled"
            frames_dir.mkdir(parents=True)
            split_command = build_split_command(
                job.source_path,
                job,
                media,
                start=start + chunk.start,
                duration=chunk.end - chunk.start,
                first_frame=1,
                fmt=options.split.format,
                jpeg_quality=options.split.jpeg_quality,
                png_compression=options.split.png_compression,
                denoise=options.split.denoise,
                tonemap=options.split.tonemap,
                decode=options.split.decode,
                output_dir=frames_dir,
                frame_limit=chunk.frame_count,
            )
            split_command[0] = str(config.ffmpeg)
            run_command(split_command, logger=logger)
            validate_frame_set(frames_dir, expected=chunk.frame_count)
            upscale_frames(
                job,
                paths,
                model=options.upscale.model,
                scale=options.upscale.scale,
                output_dir=upscaled_dir,
                tile=tile,
                batch_size=resolve_batch_size(
                    options.upscale.batch_size,
                    job.get_int("width", 1920) * (job.get_int("scale") or options.upscale.scale),
                    job.get_int("height", 1080) * (job.get_int("scale") or options.upscale.scale),
                ),
                gpu=options.upscale.gpu,
                icd=icd,
                threads=options.upscale.threads,
                retry=options.upscale.retry,
                logger=logger,
                progress=progress,
                source_dir=frames_dir,
                total_frames=chunk.frame_count,
            )
            frame_set = validate_frame_set(upscaled_dir, expected=chunk.frame_count)
            frame_width, frame_height = probe_first_frame_dimensions(
                config.ffprobe, frame_set.paths[0], logger
            )
            expected_width, expected_height = output_dimensions(
                frame_width,
                frame_height,
                options.encode.target_height or job.get_int("target_height") or None,
                options.encode.allow_huge,
            )
            segment_error: Exception | None = None
            for candidate in candidates:
                command = build_segment_command(
                    job,
                    frame_set,
                    media,
                    preset,
                    candidate,
                    options.encode,
                    segment,
                    frame_width=frame_width,
                    frame_height=frame_height,
                )
                command[0] = str(config.ffmpeg)
                try:
                    run_command(command, logger=logger)
                    segment_error = None
                    break
                except CommandError as exc:
                    segment_error = exc
            if segment_error is not None:
                raise EncodeError(
                    f"Chunk {chunk.index} encode failed",
                    hint=str(segment_error),
                )
            segment_info = probe_media(config.ffprobe, segment, logger)
            if segment_info.duration <= 0:
                raise EncodeError(f"Chunk {chunk.index} segment is invalid")
            marker.write_text("", encoding="utf-8")
            if not options.encode.keep_chunks:
                shutil.rmtree(chunk_dir, ignore_errors=True)
        if expected_width == 0 and segments:
            first_segment = probe_media(config.ffprobe, segments[0], logger)
            expected_width = first_segment.width
            expected_height = first_segment.height
        concat_output = job.chunks_dir / (
            "concat.mov" if preset.codec == "prores" else "concat.ts"
        )
        concat_segments(config.ffmpeg, segments, concat_output, logger)
        mux = build_mux_command(
            job,
            media,
            preset,
            audio_plan,
            subtitle_plan,
            options.encode,
            concat_output,
            temp_output,
            duration,
        )
        mux[0] = str(config.ffmpeg)
        run_command(mux, logger=logger)
        validate_output(
            config.ffprobe,
            temp_output,
            job,
            media,
            options.encode,
            expected_width,
            expected_height,
            audio_plan.enabled,
            len(subtitle_plan.streams),
            logger,
        )
        os.replace(temp_output, final_output)
        temp_output = None
        if not options.encode.keep_chunks:
            shutil.rmtree(job.chunks_dir, ignore_errors=True)
        job.set("preset", preset.name)
        job.set("encoder", options.encode.encoder)
        job.set("audio", audio_mode)
        job.set("subs", subs_mode)
        job.set("last_error", "")
        job.save()
        job.mark_done("assemble")
        if options.cleanup:
            _cleanup_intermediates(job)
        return RunResult(source, job, final_output, None)
    except PipelineError as exc:
        if temp_output is not None and temp_output.exists():
            try:
                temp_output.unlink()
            except OSError:
                pass
        job.set("last_error", str(exc)[:500])
        try:
            job.save()
        except OSError:
            pass
        return RunResult(source, job, None, str(exc))


def run_all(
    inputs: Sequence[Path],
    config: Config,
    options: RunOptions,
    logger: Logger,
) -> list[RunResult]:
    results: list[RunResult] = []
    for input_path in inputs:
        chunk_value = str(options.chunk_seconds).strip().lower()
        if chunk_value not in {"0", "auto"}:
            try:
                chunk_seconds = int(chunk_value)
            except ValueError as exc:
                raise ValidationError(f"Invalid --chunk-seconds: {chunk_value}") from exc
            result = _run_chunked(
                Path(input_path), config, options, chunk_seconds, logger
            )
            results.append(result)
            if result.error and options.stop_on_error:
                raise ValidationError(result.error)
            continue
        job: Job | None = None
        try:
            job = run_split([input_path], config, options.split, logger)[0]
            run_upscale([job], config, options.upscale, logger)
            outputs = run_assemble([job], config, options.encode, logger)
            output = outputs[0] if outputs else None
            if options.cleanup:
                run_clean(
                    [job],
                    config,
                    frames=False,
                    upscaled=False,
                    chunks=False,
                    sequence=False,
                    batch=False,
                    include_output=False,
                    all_intermediates=True,
                    dry_run=False,
                    logger=logger,
                )
            results.append(RunResult(input_path, job, output, None))
        except PipelineError as exc:
            results.append(RunResult(input_path, job, None, str(exc)))
            if options.stop_on_error:
                raise
    logger.info(f"{'INPUT':<32} {'STATUS':<8} OUTPUT")
    for result in results:
        status = "OK" if result.error is None else "FAILED"
        output = str(result.output) if result.output else (result.error or "-")
        logger.info(f"{result.input_path.name[:32]:<32} {status:<8} {output}")
    return results


def resolve_jobs(
    args: Sequence[str],
    config: Config,
    *,
    all_jobs: bool,
) -> list[Job]:
    if all_jobs:
        if args:
            raise UsageError("Use either job folders or --all/--all-jobs, not both.")
        jobs = find_jobs(config.work_dir)
        if not jobs:
            raise UsageError(f"No jobs found in: {config.work_dir}")
        return jobs
    if not args:
        raise UsageError(
            "No job folders given.",
            hint="Pass a job folder or use --all.",
        )
    jobs: list[Job] = []
    seen: set[Path] = set()
    for raw in args:
        job = Job.load(Path(raw).expanduser().resolve())
        if job.path not in seen:
            seen.add(job.path)
            jobs.append(job)
    return sorted(jobs, key=lambda item: item.job_id.lower())


def _default_output(job: Job, extension: str) -> Path:
    return job.output_dir / f"{job.source_path.stem}_upscaled.{extension}"


def _collision_path(path: Path) -> Path:
    if not path.exists():
        return path
    for index in range(1, 10_000):
        candidate = path.with_name(f"{path.stem}_{index}{path.suffix}")
        if not candidate.exists():
            return candidate
    raise ValidationError(f"Could not find a free output name for: {path}")


def _validate_output_path(path: Path, job: Job, extension: str) -> Path:
    resolved = path.resolve()
    if resolved == job.source_path.resolve():
        raise ValidationError(
            "Output path is the source video; refusing to overwrite it.",
            hint="Choose a different --output path.",
        )
    for directory in (
        job.frames_dir,
        job.upscaled_dir,
        job.sequence_dir,
        job.chunks_dir,
    ):
        try:
            resolved.relative_to(directory.resolve())
            raise ValidationError(
                f"Output must not be inside the job's intermediate folder: {directory}"
            )
        except ValueError:
            pass
    expected_suffix = f".{extension.lower()}"
    if resolved.suffix.lower() != expected_suffix:
        raise ValidationError(
            f"Output extension {resolved.suffix or '(none)'} does not match preset extension {expected_suffix}"
        )
    return path


def _resolve_output_path(
    job: Job,
    extension: str,
    options: EncodeOptions,
    *,
    multiple_jobs: bool,
) -> Path:
    default_name = f"{job.source_path.stem}_upscaled.{extension}"
    requested = options.output
    if requested is None:
        default = _default_output(job, extension)
        path = _collision_path(default) if (default.exists() and not options.force) else default
        return _validate_output_path(path, job, extension)

    requested = Path(requested).expanduser()
    if not requested.is_absolute():
        requested = (Path.cwd() / requested).resolve()

    if requested.exists() and not requested.is_dir() and requested.suffix == "":
        raise UsageError(f"Output path is a file without a suffix, not a directory: {requested}")

    treat_as_directory = requested.is_dir() or requested.suffix == ""
    if multiple_jobs and not treat_as_directory:
        raise UsageError(
            "With multiple jobs, --output must be a directory.",
            hint="Pass a directory (or omit --output).",
        )

    if treat_as_directory:
        path = requested / default_name
        path = _collision_path(path) if (path.exists() and not options.force) else path
        return _validate_output_path(path, job, extension)

    if requested.exists() and not options.force:
        raise ValidationError(
            f"Output already exists: {requested}",
            hint="Use --force to overwrite it.",
        )
    return _validate_output_path(requested, job, extension)


def _cleanup_intermediates(job: Job) -> None:
    for directory in (
        job.frames_dir,
        job.upscaled_dir,
        job.sequence_dir,
        job.chunks_dir,
    ):
        if directory.exists():
            shutil.rmtree(directory)


def run_assemble(
    jobs: Sequence[Job],
    config: Config,
    options: EncodeOptions,
    logger: Logger,
    *,
    dry_run: bool = False,
) -> list[Path]:
    preset = resolve_preset(options.preset)
    outputs: list[Path] = []
    multiple = len(jobs) > 1
    for job in jobs:
        temp_output: Path | None = None
        try:
            job_options = dataclasses.replace(
                options,
                target_height=(
                    options.target_height
                    if options.target_height is not None
                    else (job.get_int("target_height") or None)
                ),
            )
            if job_options.ten_bit and job.get_bool("tonemap"):
                raise ValidationError(
                    "--10bit cannot be combined with a tonemapped job."
                )
            if not dry_run:
                logger.set_log_file(job.logs_dir / "assemble.log")
            if job.source_changed() and not options.force:
                raise ValidationError(
                    f"Source changed since the job was created: {job.source_path}",
                    hint="Use --force only if the existing upscaled frames still match the source.",
                )

            media = probe_media(config.ffprobe, job.source_path, logger)
            upscaled_dir = (
                Path(options.upscaled_dir).expanduser()
                if options.upscaled_dir is not None
                else (
                    Path(job.get("upscaled_dir")).expanduser()
                    if job.get("upscaled_dir")
                    else job.upscaled_dir
                )
            )
            if not upscaled_dir.is_dir():
                raise ValidationError(
                    f"No upscaled frames found: {upscaled_dir}",
                    hint="Run Upscayl on the frames folder first, or pass --upscaled-dir.",
                )
            raw_frames = scan_frames(upscaled_dir, recursive=True)
            if not any(
                path.is_file() and path.stat().st_size > 0
                for paths in raw_frames.values()
                for path in paths
            ):
                raise ValidationError(
                    f"No upscaled frames found: {upscaled_dir}",
                    hint="Run Upscayl on the frames folder first, or pass --upscaled-dir.",
                )

            stored_count = job.get_int("frame_count")
            frame_set = validate_frame_set(
                upscaled_dir,
                expected=stored_count or None,
                pick=options.pick,
                verify=options.verify_frames,
            )

            normalized = frame_set if dry_run else build_sequence(frame_set, job, logger)
            frame_width, frame_height = probe_first_frame_dimensions(
                config.ffprobe,
                normalized.paths[0],
                logger,
            )
            expected_width, expected_height = output_dimensions(
                frame_width,
                frame_height,
                job_options.target_height,
                job_options.allow_huge,
            )

            audio_mode = options.audio or (
                config.default_audio
                if config.default_audio != "auto"
                else preset.default_audio
            )
            subs_mode = options.subs or (
                config.default_subs
                if config.default_subs != "auto"
                else preset.default_subs
            )
            audio_plan = plan_audio(
                media,
                preset,
                audio_mode,
                options.audio_bitrate,
                options.all_audio,
            )
            range_start = float(job.get("range_start") or 0.0)
            if range_start > 0:
                if any(stream.mode == "copy" for stream in audio_plan.streams):
                    logger.warn(
                        "Trimming active: copied audio is re-encoded as AAC for a sample-accurate start."
                    )
                    audio_plan = dataclasses.replace(
                        audio_plan,
                        streams=tuple(
                            dataclasses.replace(stream, mode="aac")
                            if stream.mode == "copy"
                            else stream
                            for stream in audio_plan.streams
                        ),
                    )
                if media.chapters:
                    logger.warn(
                        "Chapters come from the source and may not be shifted for the trimmed range."
                    )
            subtitle_plan = plan_subtitles(media, preset, subs_mode, logger)
            candidates = encoder_candidates(preset, options.encoder, config.ffmpeg)
            final_output = _resolve_output_path(
                job,
                preset.extension,
                job_options,
                multiple_jobs=multiple,
            )

            if dry_run:
                logger.info(f"Would assemble {job.job_id} -> {final_output}")
                outputs.append(final_output)
                continue

            temp_output = final_output.with_name(
                f"{final_output.stem}.partial{final_output.suffix}"
            )
            try:
                final_output.parent.mkdir(parents=True, exist_ok=True)
            except OSError as exc:
                raise ValidationError(
                    f"Could not create output directory: {final_output.parent}",
                    hint=str(exc),
                ) from exc
            job.clear_stage("assemble")
            last_error: CommandError | None = None
            for index, candidate in enumerate(candidates):
                command = build_assemble_command(
                    job,
                    normalized,
                    media,
                    preset,
                    candidate,
                    audio_plan,
                    subtitle_plan,
                    job_options,
                    temp_output,
                    frame_width=frame_width,
                    frame_height=frame_height,
                )
                command[0] = str(config.ffmpeg)
                try:
                    run_command(command, logger=logger)
                    last_error = None
                    break
                except CommandError as exc:
                    last_error = exc
                    if options.encoder == "auto" and index < len(candidates) - 1:
                        logger.warn(
                            f"Encoder {candidate.video_codec} failed; trying the next encoder."
                        )
                        continue
                    raise EncodeError(
                        f"Encoding failed for: {job.source_path}",
                        hint=exc.stderr_tail or str(exc),
                    ) from exc

            if last_error is not None:
                raise EncodeError(
                    f"Encoding failed for: {job.source_path}",
                    hint=last_error.stderr_tail or str(last_error),
                ) from last_error

            validate_output(
                config.ffprobe,
                temp_output,
                job,
                media,
                job_options,
                expected_width,
                expected_height,
                audio_plan.enabled,
                len(subtitle_plan.streams),
                logger,
            )
            os.replace(temp_output, final_output)
            temp_output = None
            shutil.rmtree(job.sequence_dir, ignore_errors=True)
            job.set("upscaled_count", frame_set.count)
            job.set("preset", preset.name)
            job.set("encoder", options.encoder)
            job.set("encoder_codec", candidate.video_codec)
            job.set("audio", audio_mode)
            job.set("audio_bitrate", options.audio_bitrate)
            job.set("all_audio", options.all_audio)
            job.set("subs", subs_mode)
            job.set("ten_bit", options.ten_bit)
            job.set("target_height", job_options.target_height or "")
            job.set("last_error", "")
            job.save()
            job.mark_done("assemble")
            if options.cleanup:
                _cleanup_intermediates(job)
            outputs.append(final_output)
        except PipelineError as exc:
            if temp_output is not None and temp_output.exists():
                try:
                    temp_output.unlink()
                except OSError:
                    pass
            job.set("last_error", str(exc)[:500])
            try:
                job.save()
            except OSError:
                pass
            raise
    return outputs


def run_status(config: Config, logger: Logger, *, verbose: bool = False) -> None:
    jobs = find_jobs(config.work_dir)
    if not jobs:
        logger.info(f"No jobs found in: {config.work_dir}")
        return
    logger.info(f"{'JOB':<24} {'STAGE':<10} {'FRAMES':>7} {'UPSCALED':>9}  OUTPUT")
    for job in jobs:
        frame_format = job.get("frame_format") or "png"
        frames = count_contiguous_frames(job.frames_dir, frame_format)
        upscaled = sum(
            1
            for paths in scan_frames(job.upscaled_dir, recursive=True).values()
            for path in paths
            if path.is_file() and path.stat().st_size > 0
        )
        outputs = sorted(
            path
            for path in job.output_dir.glob("*")
            if path.is_file()
        ) if job.output_dir.is_dir() else []
        output_text = "-"
        if outputs:
            output_text = f"{outputs[0].name} ({human_bytes(outputs[0].stat().st_size)})"

        if job.is_done("assemble") and outputs:
            stage = "done"
        elif job.get("last_error"):
            stage = "failed"
        elif upscaled:
            stage = "assemble"
        elif frames:
            stage = "upscale"
        elif job.is_done("split"):
            stage = "split"
        else:
            stage = "empty"

        logger.info(
            f"{job.job_id[:24]:<24} {stage:<10} {frames:>7} {upscaled:>9}  {output_text}"
        )
        if verbose:
            logger.info(f"  path: {job.path}")
            logger.info(f"  source: {job.source_path}")
            logger.info(
                "  settings: "
                + ", ".join(
                    f"{key}={job.get(key)}"
                    for key in (
                        "scale",
                        "target_height",
                        "model",
                        "frame_format",
                        "decode",
                        "preset",
                    )
                    if job.get(key) not in {None, ""}
                )
            )


def run_clean(
    jobs: Sequence[Job],
    config: Config,
    *,
    frames: bool,
    upscaled: bool,
    chunks: bool,
    sequence: bool,
    batch: bool,
    include_output: bool,
    all_intermediates: bool,
    dry_run: bool,
    logger: Logger,
) -> None:
    for job in jobs:
        ensure_within(job.path, config.work_dir)
        if not (job.path / "job.txt").is_file():
            raise ValidationError(f"Not a job folder: {job.path}")

        targets: set[Path] = set()
        if all_intermediates:
            frames = upscaled = chunks = sequence = batch = True
        if frames:
            targets.add(job.frames_dir)
        if upscaled:
            targets.add(job.upscaled_dir)
        if chunks:
            targets.add(job.chunks_dir)
        if sequence:
            targets.add(job.sequence_dir)
        if batch:
            targets.update(path for path in job.path.glob("batch_*") if path.is_dir())
        if include_output:
            targets.add(job.output_dir)

        source = job.source_path.resolve()
        for target in sorted(targets, key=lambda path: str(path)):
            target = ensure_within(target, job.path)
            if source == target or source.is_relative_to(target):
                raise ValidationError(
                    f"Refusing to delete a folder that contains the source video: {target}"
                )
            if not target.exists():
                continue
            if dry_run:
                logger.info(f"Would delete: {target}")
                continue
            if target.is_dir():
                shutil.rmtree(target)
            else:
                target.unlink()
            logger.info(f"Deleted: {target}")

        if not dry_run:
            if frames:
                job.clear_stage("split")
            if upscaled:
                job.clear_stage("upscale")
            if include_output:
                job.clear_stage("assemble")
