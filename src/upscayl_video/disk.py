"""Disk-space estimation and sample-frame measurement."""

from __future__ import annotations

import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path

from .config import Config
from .errors import CommandError, DiskSpaceError
from .frames import build_split_command
from .job import Job
from .probe import MediaInfo
from .util import Logger, human_bytes, run_command

_GIB = 1024**3


@dataclass(frozen=True)
class DiskEstimate:
    frame_bytes: int
    frame_count: int
    frames_bytes: int
    upscaled_bytes: int
    total_bytes: int
    free_bytes: int
    fits: bool


def free_bytes(path: Path) -> int:
    candidate = Path(path)
    while not candidate.exists() and candidate.parent != candidate:
        candidate = candidate.parent
    try:
        return int(shutil.disk_usage(candidate).free)
    except OSError:
        return 0


def estimate_disk(
    sample_bytes: int,
    frame_count: int,
    scale: int,
    *,
    margin_bytes: int = _GIB,
) -> DiskEstimate:
    frame_bytes = max(0, int(sample_bytes))
    count = max(0, int(frame_count))
    scale_value = max(1, int(scale))
    frames_bytes = int(round(frame_bytes * count * 1.15))
    upscaled_bytes = int(round(frame_bytes * (scale_value**2) * count * 1.15))
    total_bytes = frames_bytes + upscaled_bytes + max(0, int(margin_bytes))
    return DiskEstimate(
        frame_bytes=frame_bytes,
        frame_count=count,
        frames_bytes=frames_bytes,
        upscaled_bytes=upscaled_bytes,
        total_bytes=total_bytes,
        free_bytes=0,
        fits=False,
    )


def check_estimate(
    estimate: DiskEstimate,
    *,
    min_free_gb: int,
    max_work_gb: int,
    logger: Logger,
) -> None:
    cap = max(0, int(max_work_gb)) * _GIB
    if estimate.total_bytes > cap:
        logger.warn(
            f"Estimated work size {human_bytes(estimate.total_bytes)} exceeds "
            f"the {max_work_gb} GiB cap; a long job should use chunked processing."
        )
    floor = max(0, int(min_free_gb)) * _GIB
    remaining = estimate.free_bytes - estimate.total_bytes
    if remaining < floor:
        raise DiskSpaceError(
            f"Not enough free space: need {human_bytes(estimate.total_bytes)} "
            f"plus {min_free_gb} GiB free, have {human_bytes(estimate.free_bytes)}",
            hint="Use --work-dir on a larger drive, reduce the time range, or split the video first.",
        )


def sample_frame_bytes(
    source: Path,
    job: Job,
    media: MediaInfo,
    config: Config,
    *,
    fmt: str,
    denoise: str,
    tonemap: bool,
    decode: str,
    logger: Logger,
    start: float = 0.0,
    duration: float | None = None,
) -> int:
    del config  # The command builder reads FFmpeg through run_command's caller.
    total = duration if duration is not None else max(0.0, media.duration - start)
    offset = min(1.0, max(0.0, total * 0.1))
    sample_at = start + offset if total > 0 else start
    with tempfile.TemporaryDirectory(prefix="upscayl-sample-") as td:
        temp_dir = Path(td)
        command = build_split_command(
            Path(source),
            job,
            media,
            start=sample_at,
            duration=None,
            first_frame=1,
            fmt=fmt,
            jpeg_quality=1,
            png_compression=3,
            denoise=denoise,
            tonemap=tonemap,
            decode=decode,
            output_dir=temp_dir,
            frame_limit=1,
        )
        try:
            run_command(command, logger=logger)
            files = [path for path in temp_dir.iterdir() if path.is_file()]
            if files and files[0].stat().st_size > 0:
                return int(files[0].stat().st_size)
            reason = "sample command produced no frame"
        except CommandError as exc:
            reason = exc.stderr_tail or str(exc)

    if fmt.lower() == "jpg":
        fallback = max(1, media.width * media.height)
    else:
        fallback = max(1, media.width * media.height * 3)
    logger.warn(
        f"Could not measure a sample frame ({reason}); using {human_bytes(fallback)} per frame"
    )
    return fallback
