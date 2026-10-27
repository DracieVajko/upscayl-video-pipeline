"""Sample a video, run every Upscayl model on it, and build a comparison report."""

from __future__ import annotations

import html
import random
import re
import sys
import webbrowser
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Sequence

from .config import Config
from .errors import CommandError, DependencyError, ValidationError
from .frames import build_split_command
from .job import Job
from .probe import probe_media
from .upscayl import (
    detect_vram_mb,
    discover_upscayl,
    list_models,
    resolve_icd,
    resolve_tile,
)
from .util import Logger, atomic_write_text, human_bytes, run_command, sanitize_job_id


@dataclass(frozen=True)
class ModelTestOptions:
    frames: int = 3
    seed: int | None = None
    scale: int | None = None
    models: tuple[str, ...] = ()
    models_dir: Path | None = None
    tile: str | None = None
    gpu: int | None = None
    icd: str | None = None
    decode: str = "cpu"
    tonemap: bool | None = None
    open_report: bool = False
    dry_run: bool = False
    assume_yes: bool = False


_INDEX_RE = re.compile(r"(\d{8})")
_IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp"}


def sample_timestamps(
    duration: float,
    count: int,
    seed: int | None = None,
) -> tuple[list[float], int]:
    """Pick spread-out timestamps, one random point per equal segment."""
    if duration <= 0:
        raise ValidationError("Cannot sample a video with no duration.")
    if count <= 0:
        raise ValidationError("--frames must be greater than zero.")
    if seed is None:
        seed = random.SystemRandom().randrange(2**31)
    rng = random.Random(seed)
    segment = duration / count
    margin = segment * 0.1
    points: list[float] = []
    for index in range(count):
        low = index * segment + margin
        high = (index + 1) * segment - margin
        if high <= low:
            low, high = index * segment, (index + 1) * segment
        points.append(round(rng.uniform(low, high), 6))
    return sorted(points), seed


def collect_models(
    directories: Sequence[Path],
) -> list[tuple[str, Path]]:
    """Union of model directories, first directory wins per model name."""
    seen: dict[str, Path] = {}
    for directory in directories:
        directory = Path(directory)
        if not directory.is_dir():
            continue
        try:
            models = list_models(directory)
        except DependencyError:
            continue
        for model in models:
            seen.setdefault(model.name, directory)
    return sorted(seen.items(), key=lambda item: item[0].lower())


def _model_directories(
    config: Config,
    extra: Path | None,
) -> list[Path]:
    paths = discover_upscayl(config)
    directories: list[Path] = [paths.models_dir]
    standard = paths.binary.parent.parent / "models"
    if standard.is_dir() and standard != paths.models_dir:
        directories.append(standard)
    if config.models_dir and config.models_dir not in directories:
        directories.append(config.models_dir)
    if extra is not None:
        extra = Path(extra).expanduser().resolve()
        if extra.name.lower() != "models":
            raise DependencyError(
                f"Upscayl model directory must be named 'models': {extra}",
                hint="Rename the folder or pass a folder named models.",
            )
        if extra not in directories:
            directories.append(extra)
    return directories


def _filter_models(
    models: Sequence[tuple[str, Path]],
    requested: Sequence[str],
) -> list[tuple[str, Path]]:
    if not requested:
        return list(models)
    by_name = {name: (name, directory) for name, directory in models}
    lower = {name.lower(): (name, directory) for name, directory in models}
    selected: list[tuple[str, Path]] = []
    for raw in requested:
        found = by_name.get(raw) or lower.get(raw.lower())
        if found is None:
            raise ValidationError(
                f"Unknown model: {raw}",
                hint="Known models: " + ", ".join(sorted(by_name)),
            )
        if found not in selected:
            selected.append(found)
    return selected


def _format_time(seconds: float) -> str:
    seconds = max(0.0, float(seconds))
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    rest = seconds % 60
    if hours:
        return f"{hours:02d}:{minutes:02d}:{rest:06.3f}"
    return f"{minutes:02d}:{rest:06.3f}"


def _collect_images(directory: Path) -> dict[int, Path]:
    result: dict[int, Path] = {}
    files = sorted(
        path
        for path in directory.rglob("*")
        if path.is_file() and path.suffix.lower() in _IMAGE_SUFFIXES
    )
    for position, path in enumerate(files, 1):
        match = _INDEX_RE.search(path.stem)
        index = int(match.group(1)) if match else position
        result.setdefault(index, path)
    return result


_CSS = """
:root { color-scheme: dark; }
body { margin: 0; padding: 24px; background: #101214; color: #d7dde3;
       font: 14px/1.45 "Segoe UI", system-ui, sans-serif; }
h1 { font-size: 20px; margin: 0 0 6px; }
h2 { font-size: 15px; margin: 28px 0 10px; color: #9fb3c8; font-weight: 600; }
.meta { color: #8a99a8; font-size: 13px; }
.note { margin: 12px 0 0; padding: 10px 12px; background: #1a1f24;
        border-left: 3px solid #4a90d9; color: #b9c6d3; }
.grid { display: grid; gap: 12px;
        grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); }
.card { background: #171b1f; border: 1px solid #262d34; border-radius: 8px;
        padding: 8px; min-width: 0; }
.card.original { border-color: #2f7d5b; }
.card.error { border-color: #8a3b3b; color: #e3a3a3; }
.card img { display: block; width: 100%; height: auto; border-radius: 4px;
            background: #0b0d0f; }
.card a { color: inherit; text-decoration: none; }
.caption { display: flex; justify-content: space-between; gap: 8px;
           margin-top: 7px; font-size: 12.5px; }
.name { font-weight: 600; overflow: hidden; text-overflow: ellipsis;
        white-space: nowrap; }
.size { color: #8a99a8; white-space: nowrap; }
pre { white-space: pre-wrap; color: #e3a3a3; font-size: 12px; }
"""


def _card(
    test_dir: Path,
    label: str,
    path: Path | None,
    *,
    original: bool = False,
    error: str | None = None,
) -> str:
    if error is not None:
        return (
            '<figure class="card error">'
            f'<div class="name">{html.escape(label)}</div>'
            f"<pre>{html.escape(error)}</pre>"
            "</figure>"
        )
    if path is None or not path.is_file():
        return (
            '<figure class="card error">'
            f'<div class="name">{html.escape(label)}</div>'
            "<pre>Missing output</pre>"
            "</figure>"
        )
    relative = path.relative_to(test_dir).as_posix()
    size = human_bytes(path.stat().st_size)
    css = "card original" if original else "card"
    return (
        f'<figure class="{css}">'
        f'<a href="{html.escape(relative)}">'
        f'<img src="{html.escape(relative)}" loading="lazy" alt="{html.escape(label)}">'
        "</a>"
        '<div class="caption">'
        f'<span class="name">{html.escape(label)}</span>'
        f'<span class="size">{html.escape(size)}</span>'
        "</div>"
        "</figure>"
    )


def _report_html(
    test_dir: Path,
    video: Path,
    media,
    timestamps: Sequence[float],
    seed: int,
    models: Sequence[str],
    originals: dict[int, Path],
    outputs: dict[str, dict[int, Path]],
    failures: dict[str, str],
) -> str:
    parts: list[str] = [
        "<!doctype html>",
        '<html lang="en"><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        f"<title>Model test — {html.escape(video.name)}</title>",
        f"<style>{_CSS}</style></head><body>",
        f"<h1>Model test — {html.escape(video.name)}</h1>",
        (
            f'<div class="meta">{media.width}×{media.height} · '
            f"{_format_time(media.duration)} · seed {seed} · "
            f"{len(models)} models · {len(timestamps)} frames</div>"
        ),
        (
            '<p class="note">Compare details at 100 % (click an image). '
            "File size is not a quality score; the best model depends on the source."
            "</p>"
        ),
    ]
    for position, timestamp in enumerate(timestamps, 1):
        index = position
        parts.append(f"<h2>Frame {position} — {_format_time(timestamp)}</h2>")
        parts.append('<div class="grid">')
        parts.append(_card(test_dir, "Original", originals.get(index), original=True))
        for name in models:
            if name in failures:
                parts.append(_card(test_dir, name, None, error=failures[name]))
            else:
                parts.append(_card(test_dir, name, outputs.get(name, {}).get(index)))
        parts.append("</div>")
    parts.append("</body></html>")
    return "\n".join(parts)


def _write_manifest(
    test_dir: Path,
    video: Path,
    seed: int,
    timestamps: Sequence[float],
    models: Sequence[str],
    scale: int,
    report: Path,
) -> None:
    lines = [
        f"video={video}",
        f"seed={seed}",
        "timestamps=" + ", ".join(f"{value:.6f}" for value in timestamps),
        f"frames={len(timestamps)}",
        f"models={len(models)}",
        f"model_names={', '.join(models)}",
        f"scale={scale}",
        f"report={report}",
    ]
    atomic_write_text(test_dir / "test.txt", "\n".join(lines) + "\n")


def run_model_test(
    video: Path,
    config: Config,
    options: ModelTestOptions,
    logger: Logger,
) -> int:
    video = Path(video).expanduser().resolve()
    if not video.is_file():
        raise ValidationError(f"Video not found: {video}")

    media = probe_media(config.ffprobe, video, logger)
    timestamps, seed = sample_timestamps(media.duration, options.frames, options.seed)
    tonemap = media.hdr if options.tonemap is None else options.tonemap
    if media.hdr and not tonemap:
        raise ValidationError(
            "HDR source detected. Upscayl models are 8-bit SDR.",
            hint="Re-run without --no-tonemap to convert HDR to SDR BT.709.",
        )

    directories = _model_directories(config, options.models_dir)
    models = _filter_models(collect_models(directories), options.models)
    if not models:
        raise DependencyError(
            "No Upscayl models found.",
            hint="Set models_dir or --models-dir to a folder named models.",
        )

    scale = options.scale or config.default_scale
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    root = config.work_dir / "_model_tests" / sanitize_job_id(video.stem)
    test_dir = root / stamp
    suffix = 2
    while test_dir.exists():
        test_dir = root / f"{stamp}-{suffix}"
        suffix += 1

    total = len(models) * len(timestamps)
    logger.info(f"Video: {video}")
    logger.info(f"Duration: {_format_time(media.duration)} · {media.width}×{media.height}")
    logger.info("Frames: " + ", ".join(_format_time(value) for value in timestamps))
    logger.info(f"Seed: {seed}")
    logger.info(f"Models ({len(models)}): " + ", ".join(name for name, _ in models))
    logger.info(f"Upscales to run: {total} (scale {scale})")
    logger.info(f"Output: {test_dir}")

    if options.dry_run:
        logger.info("Dry run: nothing written.")
        return 0

    if total > 40 and not options.assume_yes and sys.stdin.isatty():
        answer = input(f"{total} Upscayl runs may take a while. Continue? [y/N] ").strip()
        if answer.lower() not in {"y", "yes"}:
            logger.info("Cancelled.")
            return 0

    original_dir = test_dir / "original"
    original_dir.mkdir(parents=True)
    paths = discover_upscayl(config)
    placeholder = Job(test_dir, {})
    for index, timestamp in enumerate(timestamps, 1):
        logger.info(f"Extract {index}/{len(timestamps)} at {_format_time(timestamp)}")
        command = build_split_command(
            video,
            placeholder,
            media,
            start=timestamp,
            duration=None,
            first_frame=index,
            fmt="png",
            jpeg_quality=1,
            png_compression=1,
            denoise="none",
            tonemap=bool(tonemap),
            decode=options.decode,
            output_dir=original_dir,
            frame_limit=1,
        )
        command[0] = str(config.ffmpeg)
        run_command(command, logger=logger)

    originals = _collect_images(original_dir)
    if len(originals) < len(timestamps):
        raise ValidationError(
            f"Only {len(originals)} of {len(timestamps)} frames were extracted.",
            hint="Check the FFmpeg log and the source timestamps.",
        )

    icd = resolve_icd(config, options.icd)
    env = {"VK_ICD_FILENAMES": str(icd)} if icd else None
    tile = resolve_tile(options.tile or config.tile, detect_vram_mb())
    gpu = config.gpu if options.gpu is None else options.gpu

    outputs: dict[str, dict[int, Path]] = {}
    failures: dict[str, str] = {}
    for position, (name, model_dir) in enumerate(models, 1):
        logger.info(f"Model {position}/{len(models)}: {name}")
        target = test_dir / name
        target.mkdir()
        command = [
            str(paths.binary),
            "-i", str(original_dir),
            "-o", str(target),
            "-m", str(model_dir),
            "-n", name,
            "-s", str(scale),
            "-g", str(gpu),
            "-t", str(tile),
            "-f", "png",
            "-c", "0",
        ]
        try:
            run_command(command, logger=logger, env=env, cwd=paths.binary.parent)
        except CommandError as exc:
            failures[name] = str(exc)
            logger.warn(f"Model failed: {name}")
            continue
        outputs[name] = _collect_images(target)

    report = test_dir / "report.html"
    atomic_write_text(
        report,
        _report_html(
            test_dir,
            video,
            media,
            timestamps,
            seed,
            [name for name, _ in models],
            originals,
            outputs,
            failures,
        ),
    )
    _write_manifest(
        test_dir,
        video,
        seed,
        timestamps,
        [name for name, _ in models],
        scale,
        report,
    )

    if len(failures) == len(models):
        logger.error("Every model failed; see the report.")
        return 6

    logger.info(f"Report: {report}")
    if failures:
        logger.warn("Failed models: " + ", ".join(sorted(failures)))
    if options.open_report:
        webbrowser.open(report.as_uri())
    return 0
