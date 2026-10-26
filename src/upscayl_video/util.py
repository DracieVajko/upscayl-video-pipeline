"""Logging, subprocess, path, time, and formatting helpers."""

from __future__ import annotations

import math
import os
import re
import shlex
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Mapping, Sequence

from .errors import CommandError, ValidationError

_RESERVED_WINDOWS_NAMES = re.compile(
    r"(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])$"
)
_INVALID_WINDOWS_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
_WHITESPACE = re.compile(r"\s+")
_MULTI_UNDERSCORE = re.compile(r"_+")


class Logger:
    """Console and file logger with a per-stage log target."""

    def __init__(
        self,
        verbose: bool = False,
        quiet: bool = False,
        log_file: Path | None = None,
    ):
        self.verbose = verbose
        self.quiet = quiet
        self.log_file: Path | None = None
        if log_file is not None:
            self.set_log_file(log_file)

    def set_log_file(self, path: Path | None) -> None:
        if path is None:
            self.log_file = None
            return
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        self.log_file = path

    def _timestamp(self) -> str:
        return datetime.now().astimezone().isoformat(timespec="seconds")

    def _write_file(self, level: str, message: str) -> None:
        if self.log_file is None:
            return
        line = f"{self._timestamp()} [{level}] {message}\n"
        with self.log_file.open("a", encoding="utf-8", newline="\n") as handle:
            handle.write(line)

    def _emit(self, level: str, message: str, *, stream) -> None:
        self._write_file(level, message)
        print(message, file=stream, flush=True)

    def info(self, message: str) -> None:
        if not self.quiet:
            self._emit("INFO", message, stream=sys.stdout)
        else:
            self._write_file("INFO", message)

    def warn(self, message: str) -> None:
        if not self.quiet:
            self._emit("WARN", message, stream=sys.stderr)
        else:
            self._write_file("WARN", message)

    def error(self, message: str) -> None:
        self._emit("ERROR", message, stream=sys.stderr)

    def debug(self, message: str) -> None:
        if self.verbose:
            self._emit("DEBUG", message, stream=sys.stdout)
        else:
            self._write_file("DEBUG", message)

    def command(
        self,
        args: Sequence[str],
        *,
        env: Mapping[str, str] | None = None,
        cwd: Path | None = None,
    ) -> None:
        text = "$ " + shlex.join(str(arg) for arg in args)
        if cwd is not None:
            text += f"  (cwd={cwd})"
        if env:
            visible = " ".join(f"{key}={value}" for key, value in sorted(env.items()))
            text += f"  (env {visible})"
        self.debug(text)


def _tail(text: str, lines: int = 50) -> str:
    if not text:
        return ""
    return "\n".join(text.splitlines()[-lines:])


def run_command(
    args: Sequence[str],
    *,
    logger: Logger,
    env: Mapping[str, str] | None = None,
    cwd: Path | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    """Run a child process and optionally raise CommandError on failure."""

    command = [str(arg) for arg in args]
    logger.command(command, env=env, cwd=cwd)
    child_env = None
    if env is not None:
        child_env = dict(os.environ)
        child_env.update({str(key): str(value) for key, value in env.items()})
    result = subprocess.run(
        command,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdin=subprocess.DEVNULL,
        capture_output=True,
        env=child_env,
        cwd=str(cwd) if cwd is not None else None,
        check=False,
    )
    if check and result.returncode != 0:
        detail = _tail(result.stderr or result.stdout)
        message = f"Command failed with exit code {result.returncode}: {shlex.join(command)}"
        if detail:
            message += f"\n{detail}"
        raise CommandError(
            message,
            returncode=result.returncode,
            stderr_tail=detail,
        )
    return result


def atomic_write_text(path: Path, text: str) -> None:
    """Write text atomically in the target directory."""

    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    try:
        with temporary.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            try:
                temporary.unlink()
            except OSError:
                pass


def read_text_utf8(path: Path) -> str:
    return Path(path).read_text(encoding="utf-8-sig")


def parse_time(value: str) -> float:
    """Parse SS, MM:SS, or HH:MM:SS (optional decimals) into seconds."""

    raw = str(value).strip()
    if not raw:
        raise ValidationError("Time value is empty")
    if raw.startswith("-"):
        raise ValidationError(f"Time value must not be negative: {value}")

    parts = raw.split(":")
    if len(parts) > 3:
        raise ValidationError(f"Invalid time value: {value}")

    numbers: list[float] = []
    for part in parts:
        if not part:
            raise ValidationError(f"Invalid time value: {value}")
        try:
            number = float(part)
        except ValueError as exc:
            raise ValidationError(f"Invalid time value: {value}") from exc
        if not math.isfinite(number) or number < 0:
            raise ValidationError(f"Invalid time value: {value}")
        numbers.append(number)

    if len(numbers) == 1:
        return numbers[0]
    if any(number >= 60 for number in numbers[1:]):
        raise ValidationError(f"Minutes and seconds must be below 60: {value}")
    if len(numbers) == 2:
        minutes, seconds = numbers
        return minutes * 60 + seconds
    hours, minutes, seconds = numbers
    return hours * 3600 + minutes * 60 + seconds


def format_duration(seconds: float) -> str:
    total_ms = int(round(float(seconds) * 1000))
    if total_ms < 0:
        total_ms = 0
    hours, remainder = divmod(total_ms, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    whole_seconds, milliseconds = divmod(remainder, 1000)
    return f"{hours:02d}:{minutes:02d}:{whole_seconds:02d}.{milliseconds:03d}"


def sanitize_job_id(stem: str) -> str:
    """Create a readable, cross-platform job folder name from a stem."""

    value = str(stem).strip()
    value = _INVALID_WINDOWS_CHARS.sub("_", value)
    value = _WHITESPACE.sub("_", value)
    value = _MULTI_UNDERSCORE.sub("_", value)
    value = value.strip("._ ")
    if not value:
        return "video"
    value = value[:80].strip("._ ")
    if not value:
        return "video"
    if _RESERVED_WINDOWS_NAMES.match(value):
        return value[:79] + "_"
    return value


def human_bytes(size: int) -> str:
    value = float(max(0, int(size)))
    if value < 1024:
        return f"{int(value)} B"
    units = ("KiB", "MiB", "GiB", "TiB", "PiB")
    for unit in units:
        value /= 1024.0
        if value < 1024 or unit == units[-1]:
            return f"{value:.1f} {unit}"
    return f"{value:.1f} PiB"


def ensure_within(path: Path, root: Path) -> Path:
    """Resolve path and ensure it is inside root."""

    resolved = Path(path).resolve()
    root_resolved = Path(root).resolve()
    try:
        resolved.relative_to(root_resolved)
    except ValueError as exc:
        raise ValidationError(
            f"Path is outside the allowed root: {resolved} (root: {root_resolved})"
        ) from exc
    return resolved
