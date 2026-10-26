"""Environment checks for the core pipeline."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path

from .config import Config
from .disk import free_bytes
from .util import Logger, human_bytes, run_command


@dataclass(frozen=True)
class CheckResult:
    name: str
    status: str
    detail: str


_ENCODER_LINE = re.compile(r"^\s*[A-Z.]{6}\s+(\S+)", re.MULTILINE)


def _first_line(text: str) -> str:
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return ""


def check_ffmpeg(config: Config, logger: Logger) -> list[CheckResult]:
    results: list[CheckResult] = []
    for name, path, marker in (
        ("ffmpeg", config.ffmpeg, "ffmpeg version"),
        ("ffprobe", config.ffprobe, "ffprobe version"),
    ):
        result = run_command([str(path), "-version"], logger=logger, check=False)
        first = _first_line(result.stdout)
        if result.returncode != 0 or marker not in first.lower():
            detail = first or _first_line(result.stderr) or f"exit code {result.returncode}"
            results.append(CheckResult(name, "FAIL", detail[:160]))
        else:
            results.append(CheckResult(name, "OK", first[:160]))

    filters = run_command(
        [str(config.ffmpeg), "-hide_banner", "-filters"],
        logger=logger,
        check=False,
    )
    if filters.returncode == 0:
        if "zscale" in filters.stdout:
            results.append(CheckResult("zscale", "OK", "available for --tonemap"))
        else:
            results.append(
                CheckResult("zscale", "WARN", "missing; --tonemap is unavailable")
            )
    else:
        results.append(CheckResult("zscale", "WARN", "could not inspect filters"))
    results.append(CheckResult("glob", "INFO", "not required by this pipeline"))
    return results


def check_encoders(config: Config, logger: Logger) -> list[CheckResult]:
    result = run_command(
        [str(config.ffmpeg), "-hide_banner", "-encoders"],
        logger=logger,
        check=False,
    )
    if result.returncode != 0:
        return [CheckResult("encoders", "FAIL", _first_line(result.stderr)[:160])]
    available = set(_ENCODER_LINE.findall(result.stdout))
    results: list[CheckResult] = []
    required = {"libx264": "required H.264 fallback"}
    preset_specific = {
        "libx265": "required for HEVC presets",
        "prores_ks": "required for mov-prores",
    }
    optional = {
        "h264_nvenc": "NVIDIA H.264",
        "hevc_nvenc": "NVIDIA HEVC",
        "h264_amf": "AMD H.264",
        "hevc_amf": "AMD HEVC",
    }
    for name, purpose in required.items():
        if name in available:
            results.append(CheckResult(name, "OK", purpose))
        else:
            results.append(CheckResult(name, "FAIL", "missing: " + purpose))
    for name, purpose in {**preset_specific, **optional}.items():
        if name in available:
            results.append(CheckResult(name, "OK", purpose))
        else:
            results.append(CheckResult(name, "WARN", "missing: " + purpose))
    return results


def check_work_dir(
    config: Config,
    work_dir: Path | None,
    logger: Logger,
) -> list[CheckResult]:
    path = Path(work_dir) if work_dir is not None else config.work_dir
    try:
        path.mkdir(parents=True, exist_ok=True)
        probe = path / f".doctor-{os.getpid()}.tmp"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
    except OSError as exc:
        return [CheckResult("work_dir", "FAIL", f"not writable: {exc}")]
    free = free_bytes(path)
    if free < config.min_free_gb * 1024**3:
        return [
            CheckResult(
                "work_dir",
                "FAIL",
                f"{human_bytes(free)} free, need {config.min_free_gb} GiB",
            )
        ]
    return [CheckResult("work_dir", "OK", f"{human_bytes(free)} free")]


def run_doctor(
    config: Config,
    *,
    work_dir: Path | None,
    skip_upscayl_smoke: bool,
    verbose: bool,
    logger: Logger,
) -> int:
    results: list[CheckResult] = []
    results.extend(check_ffmpeg(config, logger))
    results.extend(check_encoders(config, logger))
    results.extend(check_work_dir(config, work_dir, logger))
    results.append(
        CheckResult(
            "upscayl",
            "INFO",
            "checks are added with the automated upscale stage"
            if not skip_upscayl_smoke
            else "smoke test skipped",
        )
    )

    if verbose:
        logger.info(f"config: {config.config_path}")
        logger.info(f"ffmpeg: {config.ffmpeg}")
        logger.info(f"ffprobe: {config.ffprobe}")

    logger.info(f"{'STATUS':<6} {'NAME':<16} DETAIL")
    for result in results:
        logger.info(f"{result.status:<6} {result.name:<16} {result.detail}")

    disk_failed = any(
        result.name == "work_dir" and result.status == "FAIL" for result in results
    )
    required_failed = any(
        result.status == "FAIL" and result.name in {"ffmpeg", "ffprobe", "libx264"}
        for result in results
    )
    if disk_failed:
        return 5
    if required_failed:
        return 3
    return 0
