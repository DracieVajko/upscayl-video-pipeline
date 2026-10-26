"""Discovery and sizing helpers for Upscayl's CLI and models."""

from __future__ import annotations

import glob
import os
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .config import Config
from .errors import CommandError, DependencyError, UpscaleError, ValidationError
from .frames import scan_frames
from .job import Job
from .progress import Progress
from .util import Logger, run_command


@dataclass(frozen=True)
class ModelInfo:
    name: str
    param: Path
    weights: Path


@dataclass(frozen=True)
class UpscaylPaths:
    binary: Path
    models_dir: Path


def list_models(models_dir: Path) -> list[ModelInfo]:
    directory = Path(models_dir)
    if not directory.is_dir():
        raise DependencyError(f"Upscayl models directory not found: {directory}")
    models: list[ModelInfo] = []
    for param in sorted(directory.glob("*.param")):
        weights = param.with_suffix(".bin")
        if weights.is_file():
            models.append(ModelInfo(param.stem, param, weights))
    if not models:
        raise DependencyError(
            f"No complete Upscayl models found in: {directory}",
            hint="Each model needs matching .param and .bin files.",
        )
    return models


def _find_nvidia_icd_windows() -> Path | None:
    pattern = r"C:\Windows\System32\DriverStore\FileRepository\nv*\nv-vk64.json"
    matches = sorted(glob.glob(pattern))
    for match in matches:
        path = Path(match)
        if path.is_file():
            return path
    return None


def find_nvidia_icd() -> Path | None:
    if not os.name == "nt":
        return None
    return _find_nvidia_icd_windows()


def resolve_icd(config: Config, override: str | None = None) -> Path | None:
    value = (override if override is not None else config.icd or "auto").strip()
    if not value or value.lower() == "none":
        return None
    if value.lower() == "auto":
        return find_nvidia_icd()
    path = Path(value).expanduser()
    if not path.is_file():
        raise ValidationError(f"Vulkan ICD JSON not found: {path}")
    return path.resolve()


def _binary_candidates() -> list[Path]:
    names = ["upscayl-bin.exe", "upscayl-bin"] if os.name == "nt" else ["upscayl-bin"]
    candidates: list[Path] = []
    env = os.environ.get("UPSCAYL_BIN")
    if env:
        candidates.append(Path(env))
    if os.name == "nt":
        for base in (
            Path(os.environ.get("ProgramFiles", r"C:\Program Files")),
            Path(os.environ.get("LOCALAPPDATA", "")) / "Programs",
        ):
            candidates.append(base / "Upscayl" / "resources" / "bin" / names[0])
    else:
        candidates.extend(
            [
                Path("/opt/upscayl/resources/bin/upscayl-bin"),
                Path("/opt/Upscayl/resources/bin/upscayl-bin"),
                Path("/Applications/Upscayl.app/Contents/Resources/bin/upscayl-bin"),
            ]
        )
    found = shutil.which("upscayl-bin")
    if found:
        candidates.append(Path(found))
    return candidates


def _resolve_binary(config: Config) -> Path:
    if config.upscayl_bin is not None:
        configured = Path(config.upscayl_bin).expanduser()
        if configured.is_dir():
            name = "upscayl-bin.exe" if os.name == "nt" else "upscayl-bin"
            configured = configured / name
        if configured.is_file():
            return configured.resolve()
        raise DependencyError(
            f"Upscayl CLI not found: {configured}",
            hint="Set upscayl_bin in config.txt or pass --upscayl-bin.",
        )
    for candidate in _binary_candidates():
        candidate = candidate.expanduser()
        if candidate.is_dir():
            name = "upscayl-bin.exe" if os.name == "nt" else "upscayl-bin"
            candidate = candidate / name
        if candidate.is_file():
            return candidate.resolve()
    raise DependencyError(
        "Upscayl CLI not found.",
        hint="Install Upscayl or set upscayl_bin in config.txt / --upscayl-bin.",
    )


def _resolve_models_dir(config: Config, binary: Path) -> Path:
    candidates: list[Path] = []
    if config.models_dir is not None:
        candidates.append(Path(config.models_dir).expanduser())
    env = os.environ.get("UPSCAYL_MODELS")
    if env:
        candidates.append(Path(env))
    candidates.extend(
        [
            binary.parent.parent / "models",
            Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Upscayl" / "resources" / "models",
            Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "Upscayl" / "resources" / "models",
            Path("/opt/upscayl/resources/models"),
            Path("/opt/Upscayl/resources/models"),
            Path("/Applications/Upscayl.app/Contents/Resources/models"),
        ]
    )
    for candidate in candidates:
        candidate = candidate.expanduser()
        if candidate.is_dir():
            return candidate.resolve()
    raise DependencyError(
        "Upscayl models directory not found.",
        hint="Set models_dir in config.txt or pass --models-dir.",
    )


def discover_upscayl(config: Config) -> UpscaylPaths:
    binary = _resolve_binary(config)
    models = _resolve_models_dir(config, binary)
    list_models(models)
    return UpscaylPaths(binary=binary, models_dir=models)


def detect_vram_mb() -> int | None:
    smi = shutil.which("nvidia-smi")
    if smi:
        result = subprocess.run(
            [
                smi,
                "--query-gpu=memory.total",
                "--format=csv,noheader,nounits",
            ],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
        )
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                try:
                    return int(line.strip())
                except ValueError:
                    continue
    if os.name == "nt":
        try:
            result = subprocess.run(
                [
                    "wmic",
                    "path",
                    "win32_VideoController",
                    "get",
                    "AdapterRAM",
                ],
                text=True,
                encoding="utf-8",
                errors="replace",
                capture_output=True,
                check=False,
            )
        except OSError:
            return None
        if result.returncode == 0:
            values = [
                int(line.strip())
                for line in result.stdout.splitlines()
                if line.strip().isdigit()
            ]
            if values:
                return max(values) // (1024 * 1024)
    return None


def resolve_tile(requested: str, vram_mb: int | None) -> int:
    value = str(requested).strip().lower()
    if value == "auto":
        if vram_mb is None:
            return 256
        if vram_mb <= 4096:
            return 128
        if vram_mb <= 8192:
            return 256
        return 512
    try:
        tile = int(value)
    except ValueError as exc:
        raise ValidationError(f"Invalid tile size: {requested}") from exc
    if tile < 32:
        raise ValidationError("Tile size must be at least 32")
    return tile


def resolve_batch_size(requested: int, frame_width: int, frame_height: int) -> int:
    if requested > 0:
        return requested
    if frame_width * frame_height > 8_000_000:
        return 50
    return 100


def _ffmpeg_path() -> str | None:
    return shutil.which("ffmpeg")


def ffmpeg_make_test_png(path: Path, ffmpeg: str | None = None) -> None:
    binary = ffmpeg or _ffmpeg_path()
    if not binary:
        raise DependencyError("ffmpeg not found for the Upscayl smoke test")
    result = subprocess.run(
        [
            binary, "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=gray:s=64x64",
            "-frames:v", "1", str(path),
        ],
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise DependencyError(result.stderr or result.stdout or "ffmpeg smoke PNG failed")


def smoke_test(
    paths: UpscaylPaths,
    model: str,
    tile: int,
    icd: Path | None,
    logger: Logger,
    ffmpeg: Path | None = None,
) -> tuple[bool, str]:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="upscayl-smoke-") as td:
        root = Path(td)
        source = root / "in"
        target = root / "out"
        source.mkdir()
        target.mkdir()
        try:
            if ffmpeg:
                ffmpeg_make_test_png(source / "test.png", str(ffmpeg))
            else:
                ffmpeg_make_test_png(source / "test.png")
        except Exception as exc:
            return False, f"test PNG failed: {exc}"
        env = {"VK_ICD_FILENAMES": str(icd)} if icd else None
        command = [
            str(paths.binary),
            "-i", str(source),
            "-o", str(target),
            "-m", str(paths.models_dir),
            "-n", model,
            "-s", "2",
            "-g", "0",
            "-t", str(tile),
            "-f", "png",
            "-c", "0",
        ]
        try:
            run_command(
                command,
                logger=logger,
                env=env,
                cwd=paths.binary.parent,
                check=True,
            )
        except CommandError as exc:
            return False, (exc.stderr_tail or str(exc))[:500]
        except Exception as exc:
            return False, str(exc)[:500]
        output = target / "test.png"
        if not output.is_file() or output.stat().st_size <= 0:
            return False, "Upscayl produced no output file"
    return True, "OK"


def missing_indices(source_dir: Path, output_dir: Path, total: int) -> list[int]:
    source = scan_frames(source_dir)
    output = scan_frames(output_dir)
    missing: list[int] = []
    for index in range(1, total + 1):
        src = [
            path
            for path in source.get(index, [])
            if path.is_file() and path.stat().st_size > 0
        ]
        dst = [
            path
            for path in output.get(index, [])
            if path.is_file() and path.stat().st_size > 0
        ]
        if src and not dst:
            missing.append(index)
    return missing


def _source_for_index(source_dir: Path, index: int) -> Path | None:
    for path in scan_frames(source_dir).get(index, []):
        if path.is_file() and path.stat().st_size > 0:
            return path
    return None


def _output_for_stem(output_dir: Path, stem: str) -> Path | None:
    for path in output_dir.iterdir():
        if path.is_file() and path.stem == stem and path.stat().st_size > 0:
            return path
    return None


def _link_or_copy(source: Path, target: Path) -> None:
    try:
        os.link(source, target)
    except OSError:
        shutil.copy2(source, target)


def upscale_frames(
    job: Job,
    paths: UpscaylPaths,
    *,
    model: str,
    scale: int,
    output_dir: Path,
    tile: int,
    batch_size: int,
    gpu: int,
    icd: Path | None,
    threads: str,
    retry: int,
    logger: Logger,
    progress: Progress | None = None,
    source_dir: Path | None = None,
    total_frames: int | None = None,
) -> int:
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    source_dir = Path(source_dir) if source_dir is not None else job.frames_dir
    total = int(total_frames) if total_frames is not None else job.get_int("frame_count")
    if total <= 0:
        raise ValidationError(f"Job has no frame_count: {job.job_id}")
    batch_size = max(1, int(batch_size))
    tile = max(32, int(tile))
    attempt = 0
    batch_number = 1
    eta_warned = False
    env = {"VK_ICD_FILENAMES": str(icd)} if icd else None

    while True:
        missing = missing_indices(source_dir, output_dir, total)
        if not missing:
            break
        batch = missing[:batch_size]
        work = job.path / f"batch_{batch_number:04d}"
        if work.exists():
            shutil.rmtree(work)
        incoming = work / "in"
        outgoing = work / "out"
        incoming.mkdir(parents=True)
        outgoing.mkdir(parents=True)
        for index in batch:
            source = _source_for_index(source_dir, index)
            if source is None:
                raise ValidationError(f"Missing source frame {index:08d} for job {job.job_id}")
            _link_or_copy(source, incoming / source.name)
        command = [
            str(paths.binary),
            "-i", str(incoming),
            "-o", str(outgoing),
            "-m", str(paths.models_dir),
            "-n", model,
            "-s", str(scale),
            "-g", str(gpu),
            "-t", str(tile),
            "-j", threads,
            "-f", "png",
            "-c", "0",
        ]
        try:
            run_command(
                command,
                logger=logger,
                env=env,
                cwd=paths.binary.parent,
                check=True,
            )
            produced: list[Path] = []
            for source in incoming.iterdir():
                result = _output_for_stem(outgoing, source.stem)
                if result is None:
                    raise UpscaleError(
                        f"Upscayl produced no output for {source.name}"
                    )
                produced.append(result)
            for result in produced:
                target = output_dir / result.name
                if target.exists():
                    target.unlink()
                shutil.move(str(result), str(target))
        except (CommandError, UpscaleError) as exc:
            if attempt < retry:
                attempt += 1
                tile = max(64, tile // 2)
                batch_size = max(1, batch_size // 2)
                logger.warn(
                    f"Upscayl batch failed; retrying with tile={tile}, batch={batch_size}"
                )
                shutil.rmtree(work, ignore_errors=True)
                continue
            shutil.rmtree(work, ignore_errors=True)
            detail = getattr(exc, "stderr_tail", "") or str(exc)
            raise UpscaleError(
                f"Upscayl failed for job {job.job_id}",
                hint=detail[:500],
            ) from exc
        shutil.rmtree(work, ignore_errors=True)
        batch_number += 1
        attempt = 0
        if progress is not None:
            progress.update(len(batch))
            logger.info(progress.line())
            if not eta_warned and progress.eta_seconds > 12 * 3600:
                eta_warned = True
                logger.warn(
                    "Estimated upscale time exceeds 12 hours; use a faster model "
                    "(upscayl-lite-4x) or process the video in chunks."
                )
            elif not eta_warned and progress.eta_seconds > 3600:
                eta_warned = True
                logger.warn(
                    f"Estimated upscale time is {progress.eta_seconds / 3600:.1f} hours."
                )
        else:
            logger.info(f"Upscaled batch of {len(batch)} frames")

    return len(
        [
            index
            for index in range(1, total + 1)
            if any(
                path.is_file() and path.stat().st_size > 0
                for path in scan_frames(output_dir).get(index, [])
            )
        ]
    )
