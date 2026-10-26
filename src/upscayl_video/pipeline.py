"""Pipeline orchestration for split, assemble, status, and clean."""

from __future__ import annotations

import dataclasses
import glob
import shutil
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
from typing import Sequence

from .config import Config
from .disk import check_estimate, estimate_disk, free_bytes, sample_frame_bytes
from .errors import UsageError, ValidationError
from .frames import extract_frames, scan_frames
from .job import Job
from .probe import MediaInfo, parse_rational, probe_media
from .util import Logger, format_duration, human_bytes, parse_time

_VIDEO_EXTENSIONS = {
    ".mp4", ".mkv", ".mov", ".avi", ".webm", ".m4v", ".ts", ".m2ts",
    ".wmv", ".flv", ".mpg", ".mpeg", ".ogv",
}


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

        job.update_from_media(media)
        job.set("duration", f"{processed_duration:.3f}")
        job.set("range_start", f"{start:.3f}")
        job.set("range_end", "" if options.end is None else f"{end:.3f}")
        job.set("scale", scale)
        job.set("target_height", "" if target_height is None else target_height)
        job.set("model", options.model)
        job.set("frame_format", options.format.lower())
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
        job.set("frame_count", count)
        job.set("upscaled_count", 0)
        job.save()
        job.mark_done("split")
        jobs.append(job)
    return jobs
