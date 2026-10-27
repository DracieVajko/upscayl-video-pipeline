"""Two-phase workspace flow: split everything, then finish everything."""

from __future__ import annotations

import csv
import io
import shlex
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

from .config import Config
from .encode import EncodeOptions
from .errors import PipelineError, UsageError, ValidationError
from .frames import scan_frames
from .job import Job
from .pipeline import SplitOptions, find_jobs, run_assemble, run_split
from .probe import probe_media
from .util import Logger, atomic_write_text, run_command

_VIDEO_EXTENSIONS = {
    ".mp4",
    ".mov",
    ".mkv",
    ".avi",
    ".webm",
    ".m4v",
    ".mts",
    ".m2ts",
}
_BLOCKED_FFMPEG_ARGS = {
    "-i",
    "-map",
    "-filter_complex",
    "-lavfi",
    "-vf",
    "-filter:v",
    "-y",
    "-n",
    "-f",
}


@dataclass(frozen=True)
class SplitAllOptions:
    format: str = "png"
    png_compression: int = 1
    jpeg_quality: int = 1
    denoise: str = "none"
    decode: str = "auto"
    tonemap: bool | None = None
    scale: int | None = None
    model: str | None = None
    assume_yes: bool = False
    dry_run: bool = False
    force: bool = False


@dataclass(frozen=True)
class FinishOptions:
    all_jobs: bool = False
    jobs: tuple[str, ...] = ()
    profile: str = "default"
    preset: str | None = None
    encoder: str | None = None
    quality: str | None = None
    crf: int | None = None
    audio: str | None = None
    audio_bitrate: int = 192
    all_audio: bool = False
    subs: str | None = None
    ten_bit: bool = False
    ffmpeg_args: tuple[str, ...] = ()
    keep: bool = False
    force: bool = False
    assume_yes: bool = False


def parse_ffmpeg_args(value: str | None) -> tuple[str, ...]:
    if not value or not str(value).strip():
        return ()
    try:
        tokens = shlex.split(str(value))
    except ValueError as exc:
        raise ValidationError(f"Could not parse --ffmpeg-args: {exc}") from exc
    blocked = [token for token in tokens if token in _BLOCKED_FFMPEG_ARGS]
    if blocked:
        raise ValidationError(
            "Blocked FFmpeg arguments: " + ", ".join(blocked),
            hint="Input, mapping, filters, and overwrite flags are controlled by the pipeline.",
        )
    return tuple(tokens)


def _video_inputs(directory: Path) -> list[Path]:
    return sorted(
        path
        for path in directory.rglob("*")
        if path.is_file() and path.suffix.lower() in _VIDEO_EXTENSIONS
    )


def _format_time(seconds: float) -> str:
    seconds = max(0.0, float(seconds))
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    rest = seconds % 60
    return f"{hours:d}:{minutes:02d}:{rest:06.3f}" if hours else f"{minutes:02d}:{rest:06.3f}"


def _split_one(
    source: Path,
    media,
    config: Config,
    options: SplitAllOptions,
    logger: Logger,
) -> Job:
    tonemap = media.hdr if options.tonemap is None else options.tonemap
    if media.hdr and not tonemap:
        raise ValidationError(
            "HDR source detected. Upscayl models are 8-bit SDR.",
            hint="Re-run with --tonemap to convert HDR to SDR BT.709.",
        )
    split = SplitOptions(
        fps=None,
        start=None,
        end=None,
        format=options.format,
        jpeg_quality=options.jpeg_quality,
        png_compression=options.png_compression,
        denoise=options.denoise,
        tonemap=bool(tonemap),
        decode=options.decode,
        scale=options.scale or config.default_scale,
        target_height=None,
        model=options.model or config.default_model,
        verify_frames=False,
        recursive=False,
        force=options.force,
    )
    return run_split([source], config, split, logger)[0]


def _convert_layout(job: Job, logger: Logger) -> None:
    outgoing = job.path / "batch00001" / "out"
    if job.data.get("frames_dir"):
        outgoing.mkdir(parents=True, exist_ok=True)
        return
    if not job.frames_dir.is_dir():
        raise ValidationError(f"Split produced no frames: {job.frames_dir}")
    batch = job.path / "batch00001"
    incoming = batch / "in"
    if incoming.exists():
        shutil.rmtree(incoming)
    batch.mkdir(parents=True, exist_ok=True)
    job.frames_dir.rename(incoming)
    outgoing.mkdir(parents=True, exist_ok=True)
    job.set("frames_dir", "batch00001/in")
    job.set("upscaled_dir", "batch00001/out")
    job.set("layout", "batches")
    job.save()
    logger.info(f"Frames: {incoming}")


def _extract_audio(job: Job, media, config: Config, logger: Logger) -> None:
    audio_dir = job.audio_dir
    if job.data.get("audio_tracks") is not None and audio_dir.is_dir():
        return
    audio_dir.mkdir(parents=True, exist_ok=True)
    if not media.audio:
        job.set("audio_tracks", 0)
        job.save()
        atomic_write_text(audio_dir / "info.txt", "tracks=0\n")
        return
    lines = [f"tracks={len(media.audio)}"]
    for index, stream in enumerate(media.audio, 1):
        target = audio_dir / f"track{index:02d}.mka"
        command = [
            str(config.ffmpeg), "-hide_banner", "-nostdin", "-y",
            "-i", str(job.source_path),
            "-map", f"0:{stream.index}",
            "-vn", "-sn", "-dn", "-c", "copy", str(target),
        ]
        try:
            run_command(command, logger=logger)
        except PipelineError:
            command = [
                str(config.ffmpeg), "-hide_banner", "-nostdin", "-y",
                "-i", str(job.source_path),
                "-map", f"0:{stream.index}",
                "-vn", "-sn", "-dn", "-c:a", "flac", str(target),
            ]
            run_command(command, logger=logger)
        lines.extend(
            [
                "",
                f"track={index:02d}",
                f"index={stream.index}",
                f"codec={stream.codec_name}",
                f"channels={stream.channels or ''}",
                f"language={stream.language or ''}",
                f"title={stream.title or ''}",
                f"file={target.name}",
            ]
        )
    job.set("audio_tracks", len(media.audio))
    job.save()
    atomic_write_text(audio_dir / "info.txt", "\n".join(lines) + "\n")
    logger.info(f"Audio: {audio_dir}")


def _write_manifest(config: Config, jobs: Sequence[Job]) -> None:
    manifest = config.work_dir / "manifest.csv"
    readme = config.work_dir / "README-UPScayl.txt"
    if not jobs:
        for path in (manifest, readme):
            try:
                path.unlink()
            except FileNotFoundError:
                pass
        return

    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    writer.writerow(["job", "source", "frames", "in", "out", "audio_tracks", "output"])
    for job in jobs:
        writer.writerow(
            [
                job.job_id,
                str(job.source_path),
                job.get("frame_count") or "",
                str(job.frames_dir),
                str(job.upscaled_dir),
                job.get("audio_tracks") or "0",
                str(job.output_dir),
            ]
        )
    atomic_write_text(manifest, buffer.getvalue())

    lines = [
        "Upscayl Video Pipeline - workspace",
        "",
        "For each job, point the Upscayl GUI at:",
        "  Input:  <job>\\batch00001\\in",
        "  Output: <job>\\batch00001\\out",
        "",
        "Then run: upscayl-video finish --all",
        "",
        "Jobs:",
    ]
    for job in jobs:
        lines.append(f"  {job.job_id}: {job.path}")
    lines.extend(
        [
            "",
            "The audio folder holds a lossless copy of every audio track.",
            "finish moves the video to output_dir and removes the job folder.",
        ]
    )
    atomic_write_text(readme, "\n".join(lines) + "\n")


def run_split_all(config: Config, options: SplitAllOptions, logger: Logger) -> int:
    input_dir = config.input_dir
    input_dir.mkdir(parents=True, exist_ok=True)
    sources = _video_inputs(input_dir)
    if not sources:
        raise UsageError(
            f"No videos found in: {input_dir}",
            hint="Put the original videos in the input folder and run again.",
        )

    media_by_source = {}
    total_frames = 0
    for source in sources:
        media = probe_media(config.ffprobe, source, logger)
        media_by_source[source] = media
        frames = int(round(media.duration * media.fps_decimal))
        total_frames += max(frames, 0)
        logger.info(
            f"{source.name}: {_format_time(media.duration)}, "
            f"{frames} frames, {media.width}x{media.height}"
            + (" [HDR]" if media.hdr else "")
        )

    logger.info(f"Inputs: {len(sources)} · frames: {total_frames} · work: {config.work_dir}")
    if options.dry_run:
        logger.info("Dry run: nothing written.")
        return 0
    if not options.assume_yes and sys.stdin.isatty():
        answer = input(f"Split {len(sources)} video(s) into {config.work_dir}? [y/N] ").strip()
        if answer.lower() not in {"y", "yes"}:
            logger.info("Cancelled.")
            return 0

    created: list[Job] = []
    failures: list[tuple[Path, str]] = []
    for source in sources:
        try:
            logger.info(f"Splitting: {source.name}")
            job = _split_one(source, media_by_source[source], config, options, logger)
            _convert_layout(job, logger)
            _extract_audio(job, media_by_source[source], config, logger)
            created.append(job)
        except PipelineError as exc:
            logger.error(f"{source.name}: {exc}")
            failures.append((source, str(exc)))

    _write_manifest(config, find_jobs(config.work_dir))
    logger.info(f"Split complete: {len(created)} job(s)")
    for job in created:
        logger.info(f"  {job.job_id}: {job.frames_dir} -> {job.upscaled_dir}")
    if failures:
        logger.error(f"Failed: {len(failures)}")
        return 1
    return 0


def _upscaled_count(job: Job) -> int:
    return sum(
        len(paths)
        for paths in scan_frames(job.upscaled_dir, recursive=True).values()
        if any(path.is_file() and path.stat().st_size > 0 for path in paths)
    )


def _select_jobs(jobs: Sequence[Job], options: FinishOptions) -> list[Job]:
    if options.jobs:
        wanted = {name.lower() for name in options.jobs}
        selected = [job for job in jobs if job.job_id.lower() in wanted]
        missing = wanted - {job.job_id.lower() for job in selected}
        if missing:
            raise ValidationError(
                "Unknown job(s): " + ", ".join(sorted(missing)),
                hint="Known jobs: " + ", ".join(job.job_id for job in jobs),
            )
        return selected
    if options.all_jobs:
        return list(jobs)
    if not sys.stdin.isatty():
        raise UsageError("Use --all or --job NAME when not running interactively.")
    if not jobs:
        return []
    print("Jobs:")
    for index, job in enumerate(jobs, 1):
        count = _upscaled_count(job)
        expected = job.get("frame_count") or "?"
        print(f"  {index}) {job.job_id} — {count}/{expected} upscaled")
    answer = input("Job number or 'a' for all: ").strip().lower()
    if answer in {"a", "all"}:
        return list(jobs)
    if answer.isdigit():
        index = int(answer)
        if 1 <= index <= len(jobs):
            return [jobs[index - 1]]
    raise UsageError("Invalid job selection.")


def _encode_options(config: Config, options: FinishOptions) -> EncodeOptions:
    preset = options.preset
    quality = options.quality
    encoder = options.encoder
    if options.profile == "fast":
        preset = preset or "mp4-h264"
        quality = quality or "fast"
        encoder = encoder or "auto"
    elif options.profile == "quality":
        preset = preset or "mp4-hevc"
        quality = quality or "quality"
        encoder = encoder or "auto"
    else:
        preset = preset or config.default_preset
        quality = quality or "balanced"
        encoder = encoder or config.default_encoder
    return EncodeOptions(
        preset=preset,
        encoder=encoder,
        quality=quality,
        crf=options.crf,
        audio=options.audio,
        audio_bitrate=options.audio_bitrate,
        all_audio=options.all_audio,
        subs=options.subs,
        ten_bit=options.ten_bit,
        cleanup=not options.keep,
        force=options.force,
        ffmpeg_args=options.ffmpeg_args,
    )


def run_finish(config: Config, options: FinishOptions, logger: Logger) -> int:
    if options.crf is not None and options.quality is not None:
        raise ValidationError("--quality and --crf are mutually exclusive.")
    jobs = find_jobs(config.work_dir)
    if not jobs:
        logger.info(f"No jobs found in: {config.work_dir}")
        return 0
    selected = _select_jobs(jobs, options)
    if not selected:
        logger.info("Nothing selected.")
        return 0

    encode = _encode_options(config, options)
    done = 0
    skipped = 0
    failures: list[tuple[str, str]] = []
    for job in selected:
        count = _upscaled_count(job)
        if count == 0:
            logger.warn(f"Skipping {job.job_id}: no upscaled frames in {job.upscaled_dir}")
            skipped += 1
            continue
        try:
            logger.info(f"Assembling {job.job_id} ({count} frames)")
            outputs = run_assemble([job], config, encode, logger)
            if outputs:
                logger.info(f"Output: {outputs[0]}")
            done += 1
        except PipelineError as exc:
            logger.error(f"{job.job_id}: {exc}")
            failures.append((job.job_id, str(exc)))

    _write_manifest(config, find_jobs(config.work_dir))
    logger.info(f"Finished: {done} · skipped: {skipped} · failed: {len(failures)}")
    if failures:
        for job_id, message in failures:
            logger.error(f"  {job_id}: {message}")
        return 1
    return 0
