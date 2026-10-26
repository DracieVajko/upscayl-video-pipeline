"""Frame extraction, validation, matching, and sequence normalization."""

from __future__ import annotations

import os
import re
import shutil
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from .config import Config
from .errors import CommandError, EncodeError, ValidationError
from .job import Job
from .probe import MediaInfo
from .util import Logger, run_command

_FRAME_RE = re.compile(
    r"^frame_(\d{8})(?:[_\-.].*)?\.(png|jpe?g|webp)$",
    re.IGNORECASE,
)
_DENOISE = {
    "none": None,
    "light": "hqdn3d=1.5:1.5:6:6",
    "medium": "hqdn3d=2:2:8:8",
    "strong": "hqdn3d=3:3:10:10",
}
_TONEMAP = (
    "zscale=t=linear:npl=100,format=gbrpf32le,"
    "zscale=p=bt709,tonemap=tonemap=hable:desat=0,"
    "zscale=t=bt709:m=bt709:r=tv,format=yuv420p"
)


@dataclass(frozen=True)
class FrameSet:
    directory: Path
    extension: str
    indices: tuple[int, ...]
    paths: tuple[Path, ...]

    @property
    def count(self) -> int:
        return len(self.paths)

    @property
    def first_index(self) -> int:
        return self.indices[0] if self.indices else 0

    @property
    def last_index(self) -> int:
        return self.indices[-1] if self.indices else 0

    @property
    def is_normalized(self) -> bool:
        if not self.paths:
            return False
        for index, path in zip(self.indices, self.paths):
            if path.name != f"frame_{index:08d}.{self.extension}":
                return False
        return True


def frame_pattern(fmt: str) -> str:
    value = str(fmt).lower().strip()
    if value == "png":
        return "frame_%08d.png"
    if value in {"jpg", "jpeg"}:
        return "frame_%08d.jpg"
    raise ValidationError(f"Unsupported frame format: {fmt}")


def check_frame_signature(path: Path) -> bool:
    try:
        header = Path(path).read_bytes()[:12]
    except OSError:
        return False
    if header.startswith(b"\x89PNG\r\n\x1a\n"):
        return True
    if header.startswith(b"\xff\xd8\xff"):
        return True
    if header.startswith(b"RIFF") and header[8:12] == b"WEBP":
        return True
    return False


def scan_frames(directory: Path, *, recursive: bool = False) -> dict[int, list[Path]]:
    directory = Path(directory)
    found: dict[int, list[Path]] = {}
    if not directory.is_dir():
        return found

    def add(path: Path) -> None:
        match = _FRAME_RE.match(path.name)
        if not match:
            return
        index = int(match.group(1))
        found.setdefault(index, []).append(path)

    for child in directory.iterdir():
        if child.is_file():
            add(child)
        elif recursive and child.is_dir():
            try:
                for nested in child.iterdir():
                    if nested.is_file():
                        add(nested)
            except OSError:
                continue
    return found


def count_contiguous_frames(directory: Path, extension: str) -> int:
    frames = scan_frames(directory, recursive=False)
    count = 0
    while True:
        index = count + 1
        paths = [
            path
            for path in frames.get(index, [])
            if path.is_file() and path.stat().st_size > 0
        ]
        if not paths:
            return count
        count += 1


def validate_frame_set(
    directory: Path,
    *,
    expected: int | None,
    pick: str = "error",
    verify: bool = False,
) -> FrameSet:
    directory = Path(directory)
    raw = scan_frames(directory, recursive=True)
    selected: dict[int, Path] = {}

    for index, paths in raw.items():
        valid = [path for path in paths if path.is_file() and path.stat().st_size > 0]
        if not valid:
            continue
        if len(valid) > 1:
            if pick == "error":
                listing = ", ".join(str(path) for path in valid)
                raise ValidationError(
                    f"Multiple frames for index {index:08d}: {listing}",
                    hint="Use --pick newest or --pick largest, or remove duplicates.",
                )
            if pick == "newest":
                selected[index] = max(valid, key=lambda path: (path.stat().st_mtime, path.name))
            elif pick == "largest":
                selected[index] = max(valid, key=lambda path: (path.stat().st_size, path.name))
            else:
                raise ValidationError(f"Unknown --pick mode: {pick}")
        else:
            selected[index] = valid[0]

    if not selected:
        raise ValidationError(f"No valid frames found in: {directory}")

    indices = sorted(selected)
    maximum = max(indices[-1], 1)
    if expected is not None:
        maximum = max(maximum, expected)
    missing = [index for index in range(1, maximum + 1) if index not in selected]
    extra = [index for index in indices if expected is not None and index > expected]
    if missing or extra:
        details = []
        if missing:
            details.append("missing: " + ", ".join(f"{index:08d}" for index in missing[:20]))
        if extra:
            details.append("unexpected: " + ", ".join(f"{index:08d}" for index in extra[:20]))
        raise ValidationError(
            f"Frame set is not contiguous in: {directory}",
            hint="; ".join(details),
        )

    extensions = {path.suffix.lower().lstrip(".") for path in selected.values()}
    if len(extensions) != 1:
        raise ValidationError(
            "Mixed frame formats are not supported: "
            + ", ".join(sorted(extensions))
        )
    extension = extensions.pop()

    if verify:
        for index in indices:
            if not check_frame_signature(selected[index]):
                raise ValidationError(
                    f"Invalid frame signature at index {index:08d}: {selected[index]}"
                )

    return FrameSet(
        directory=directory,
        extension=extension,
        indices=tuple(indices),
        paths=tuple(selected[index] for index in indices),
    )


def build_sequence(frame_set: FrameSet, job: Job, logger: Logger) -> FrameSet:
    if frame_set.is_normalized:
        return frame_set
    if frame_set.count == 0:
        raise ValidationError("Cannot build an image sequence from zero frames")
    sequence = job.sequence_dir
    if sequence.exists():
        shutil.rmtree(sequence)
    sequence.mkdir(parents=True, exist_ok=True)
    targets: list[Path] = []
    for index, source in zip(frame_set.indices, frame_set.paths):
        target = sequence / f"frame_{index:08d}.{frame_set.extension}"
        try:
            os.link(source, target)
        except OSError:
            shutil.copy2(source, target)
        targets.append(target)
    logger.debug(f"Normalized {len(targets)} frames into {sequence}")
    return FrameSet(
        directory=sequence,
        extension=frame_set.extension,
        indices=frame_set.indices,
        paths=tuple(targets),
    )


def _hwaccel_args(decode: str) -> list[str]:
    if decode != "gpu":
        return []
    if sys.platform.startswith("win"):
        if shutil.which("nvidia-smi"):
            return ["-hwaccel", "cuda"]
        return ["-hwaccel", "d3d11va"]
    if sys.platform == "darwin":
        return ["-hwaccel", "videotoolbox"]
    if Path("/dev/dri/renderD128").exists():
        return ["-hwaccel", "vaapi", "-hwaccel_device", "/dev/dri/renderD128"]
    return []


def build_split_command(
    source: Path,
    job: Job,
    media: MediaInfo,
    *,
    start: float,
    duration: float | None,
    first_frame: int,
    fmt: str,
    jpeg_quality: int,
    png_compression: int,
    denoise: str,
    tonemap: bool,
    decode: str,
    output_dir: Path | None = None,
    frame_limit: int | None = None,
) -> list[str]:
    fmt = str(fmt).lower()
    if fmt not in {"png", "jpg"}:
        raise ValidationError(f"Unsupported frame format: {fmt}")
    if denoise not in _DENOISE:
        raise ValidationError(f"Unsupported denoise mode: {denoise}")
    fps = media.fps_rational if media.fps_den else "30/1"
    output_dir = Path(output_dir) if output_dir is not None else job.frames_dir
    pattern = frame_pattern(fmt)

    args = [
        "ffmpeg",
        "-hide_banner",
        "-nostdin",
        "-y",
        "-benchmark",
    ]
    args.extend(_hwaccel_args(decode))
    if start > 0:
        args.extend(["-ss", f"{start:.6f}"])
    args.extend(["-i", str(source)])
    if duration is not None:
        args.extend(["-t", f"{duration:.6f}"])
    args.extend(
        [
            "-map",
            "0:v:0",
            "-an",
            "-sn",
            "-dn",
            "-fps_mode",
            "cfr",
            "-r",
            fps,
            "-start_number",
            str(first_frame),
        ]
    )
    if frame_limit is not None:
        args.extend(["-frames:v", str(frame_limit)])

    filters: list[str] = []
    if tonemap:
        filters.append(_TONEMAP)
    denoise_filter = _DENOISE.get(denoise)
    if denoise_filter:
        filters.append(denoise_filter)
    if media.width % 2 or media.height % 2:
        filters.append("pad=ceil(iw/2)*2:ceil(ih/2)*2")
    filters.append("format=rgb24" if fmt == "png" else "format=yuvj420p")
    args.extend(["-vf", ",".join(filters)])

    if fmt == "png":
        args.extend(["-compression_level", str(png_compression)])
    else:
        args.extend(["-q:v", str(jpeg_quality)])

    args.append(str(output_dir / pattern))
    return args


def _benchmark_decode(
    source: Path,
    media: MediaInfo,
    decode: str,
    logger: Logger,
) -> float | None:
    with tempfile.TemporaryDirectory(prefix="upscayl-bench-") as td:
        output = Path(td) / "frame_%08d.png"
        args = [
            "ffmpeg",
            "-hide_banner",
            "-nostdin",
            "-y",
            "-benchmark",
        ]
        args.extend(_hwaccel_args(decode))
        args.extend(
            [
                "-i",
                str(source),
                "-map",
                "0:v:0",
                "-an",
                "-sn",
                "-dn",
                "-fps_mode",
                "cfr",
                "-r",
                media.fps_rational if media.fps_den else "30/1",
                "-frames:v",
                "30",
                "-compression_level",
                "3",
                str(output),
            ]
        )
        try:
            result = run_command(args, logger=logger)
        except CommandError:
            return None
        matches = re.findall(r"bench:.*?rtime=([0-9.]+)", result.stderr)
        if not matches:
            return None
        return float(matches[-1])


def choose_decode(source: Path, media: MediaInfo, config: Config, logger: Logger) -> str:
    del config
    # The caller validates the CLI value; this function only handles auto.
    if media.fps_den == 0 or not _hwaccel_args("gpu"):
        return "cpu"
    logger.debug("Benchmarking CPU and GPU frame extraction")
    cpu_time = _benchmark_decode(source, media, "cpu", logger)
    gpu_time = _benchmark_decode(source, media, "gpu", logger)
    if cpu_time is None and gpu_time is None:
        logger.warn("Decode benchmark failed; using CPU")
        return "cpu"
    if gpu_time is not None and (cpu_time is None or gpu_time < cpu_time):
        logger.info(f"Decode benchmark: GPU {gpu_time:.2f}s vs CPU {cpu_time or 0:.2f}s; using GPU")
        return "gpu"
    logger.info(f"Decode benchmark: CPU {cpu_time or 0:.2f}s vs GPU {gpu_time or 0:.2f}s; using CPU")
    return "cpu"


def extract_frames(
    job: Job,
    media: MediaInfo,
    config: Config,
    *,
    fmt: str,
    jpeg_quality: int,
    png_compression: int,
    denoise: str,
    tonemap: bool,
    decode: str,
    start: float,
    end: float | None,
    verify: bool,
    logger: Logger,
    dry_run: bool = False,
) -> int:
    if decode not in {"cpu", "gpu", "auto"}:
        raise ValidationError(f"Unsupported decode mode: {decode}")
    fps = media.fps_decimal or 30.0
    total_duration = max(0.0, (end if end is not None else media.duration) - start)
    expected = int(round(total_duration * fps))
    if expected <= 0:
        return 0
    if media.hdr and not tonemap:
        raise ValidationError(
            "HDR source detected. Upscayl models are 8-bit SDR.",
            hint="Re-run with --tonemap to convert HDR to SDR BT.709.",
        )
    if tonemap and not media.hdr:
        logger.warn("--tonemap was requested for a non-HDR source; applying the SDR conversion anyway")

    chosen = decode
    if decode == "auto":
        chosen = choose_decode(job.source_path, media, config, logger)
        job.set("decode", chosen)
        logger.info(f"Frame decode path: {chosen}")
    elif decode == "gpu":
        job.set("decode", "gpu")
    else:
        job.set("decode", "cpu")

    frames = scan_frames(job.frames_dir, recursive=False)
    total_files = sum(
        1
        for paths in frames.values()
        for path in paths
        if path.is_file() and path.stat().st_size > 0
    )
    existing = count_contiguous_frames(job.frames_dir, "jpg" if fmt == "jpg" else "png")
    if total_files > existing:
        raise ValidationError(
            f"Existing frame set is not contiguous: {job.frames_dir}",
            hint="Use --force to start the split over.",
        )
    if existing > expected:
        raise ValidationError(
            f"More frames exist than expected ({existing} > {expected})",
            hint="Use --force to start the split over.",
        )
    if existing == expected:
        return existing

    first_frame = existing + 1
    adjusted_start = start + (existing / fps if existing else 0.0)
    remaining = expected - existing
    command = build_split_command(
        job.source_path,
        job,
        media,
        start=adjusted_start,
        duration=remaining / fps,
        first_frame=first_frame,
        fmt=fmt,
        jpeg_quality=jpeg_quality,
        png_compression=png_compression,
        denoise=denoise,
        tonemap=tonemap,
        decode=chosen,
        frame_limit=remaining,
    )
    if dry_run:
        logger.info(" ".join(command))
        return expected

    job.frames_dir.mkdir(parents=True, exist_ok=True)
    try:
        run_command(command, logger=logger)
    except CommandError as exc:
        if chosen == "gpu":
            logger.warn("GPU frame extraction failed; retrying with CPU")
            job.set("decode", "cpu")
            command = build_split_command(
                job.source_path,
                job,
                media,
                start=adjusted_start,
                duration=remaining / fps,
                first_frame=first_frame,
                fmt=fmt,
                jpeg_quality=jpeg_quality,
                png_compression=png_compression,
                denoise=denoise,
                tonemap=tonemap,
                decode="cpu",
                frame_limit=remaining,
            )
            try:
                run_command(command, logger=logger)
            except CommandError as retry_exc:
                raise EncodeError(
                    f"Frame extraction failed: {job.source_path}",
                    hint=retry_exc.stderr_tail or str(retry_exc),
                ) from retry_exc
        else:
            raise EncodeError(
                f"Frame extraction failed: {job.source_path}",
                hint=exc.stderr_tail or str(exc),
            ) from exc

    frame_set = validate_frame_set(
        job.frames_dir,
        expected=expected,
        verify=verify,
    )
    return frame_set.count
