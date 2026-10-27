"""Configuration loading, validation, and executable discovery."""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence

from .errors import DependencyError, ValidationError
from .util import read_text_utf8

DEFAULTS: dict[str, str] = {
    "ffmpeg": "ffmpeg",
    "ffprobe": "ffprobe",
    "upscayl_bin": "auto",
    "models_dir": "auto",
    "work_dir": "work",
    "output_dir": "output",
    "input_dir": "input",
    "default_model": "upscayl-standard-4x",
    "default_scale": "2",
    "default_preset": "mp4-h264",
    "default_encoder": "auto",
    "default_audio": "auto",
    "default_subs": "auto",
    "tile": "auto",
    "batch_size": "100",
    "gpu": "0",
    "icd": "auto",
    "max_work_gb": "40",
    "min_free_gb": "5",
    "cleanup": "0",
}

_PRESETS = {"mp4-h264", "mp4-hevc", "mkv-hevc", "mov-prores"}
_ENCODERS = {"auto", "nvidia", "amd", "cpu"}
_AUDIO_MODES = {"auto", "copy", "aac", "pcm", "none"}
_SUBS_MODES = {"auto", "copy", "convert", "none"}


@dataclass(frozen=True)
class Config:
    ffmpeg: Path
    ffprobe: Path
    upscayl_bin: Path | None
    models_dir: Path | None
    work_dir: Path
    output_dir: Path
    input_dir: Path
    default_model: str
    default_scale: int
    default_preset: str
    default_encoder: str
    default_audio: str
    default_subs: str
    tile: str
    batch_size: int
    gpu: int
    icd: str
    max_work_gb: int
    min_free_gb: int
    cleanup: bool
    config_path: Path
    tool_dir: Path


def _is_path_like(value: str) -> bool:
    if not value:
        return False
    path = Path(value).expanduser()
    if path.is_absolute():
        return True
    if os.sep in value or "/" in value or "\\" in value:
        return True
    if os.name == "nt" and ":" in value:
        return True
    return False


def _names_for(tool: str) -> list[str]:
    if os.name == "nt":
        return [tool + ".exe", tool]
    return [tool]


def _search_dirs(base: Path) -> list[Path]:
    dirs = [base, base.parent]
    if os.name == "nt":
        dirs.append(Path("C:/ffmpeg/bin"))
        dirs.append(Path("C:/Program Files/ffmpeg/bin"))
    else:
        dirs.extend([Path("/usr/bin"), Path("/usr/local/bin"), Path("/opt/homebrew/bin")])
    unique: list[Path] = []
    seen: set[Path] = set()
    for directory in dirs:
        if directory not in seen:
            seen.add(directory)
            unique.append(directory)
    return unique


def resolve_tool_path(
    value: str,
    *,
    names: Sequence[str],
    search_dirs: Sequence[Path],
) -> Path:
    """Resolve a configured executable, directory, or bare command name."""

    raw = str(value).strip()
    searched: list[Path] = []

    if raw and _is_path_like(raw):
        candidate = Path(raw).expanduser()
        if candidate.is_dir():
            for name in names:
                path = candidate / name
                searched.append(path)
                if path.is_file():
                    return path.resolve()
            raise DependencyError(
                f"Executable not found in directory: {candidate}",
                hint="Searched: " + ", ".join(str(path) for path in searched),
            )
        if candidate.is_file():
            return candidate.resolve()
        searched.append(candidate)
        raise DependencyError(
            f"Executable does not exist: {candidate}",
            hint="Searched: " + ", ".join(str(path) for path in searched),
        )

    if raw:
        found = shutil.which(raw)
        if found:
            return Path(found).resolve()
        searched.append(Path(raw))

    for directory in search_dirs:
        for name in names:
            path = Path(directory) / name
            searched.append(path)
            if path.is_file():
                return path.resolve()

    for name in names:
        found = shutil.which(name)
        if found:
            return Path(found).resolve()

    raise DependencyError(
        f"Executable not found: {raw or (names[0] if names else 'unknown')}",
        hint="Searched: " + ", ".join(str(path) for path in searched),
    )


def _parse_int(value: str, key: str) -> int:
    try:
        return int(str(value).strip())
    except (TypeError, ValueError) as exc:
        raise ValidationError(f"Invalid integer for {key}: {value!r}") from exc


def _parse_bool(value: str, key: str) -> bool:
    text = str(value).strip().lower()
    if text in {"1", "true", "yes", "on"}:
        return True
    if text in {"0", "false", "no", "off", ""}:
        return False
    raise ValidationError(f"Invalid boolean for {key}: {value!r}")


def _read_values(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    values: dict[str, str] = {}
    for line in read_text_utf8(path).splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.strip()
        if key in DEFAULTS:
            values[key] = value.strip()
    return values


def load_config(
    config_path: Path | None = None,
    *,
    overrides: Mapping[str, str] | None = None,
    tool_dir: Path | None = None,
) -> Config:
    if config_path is None:
        base = Path(tool_dir).resolve() if tool_dir is not None else Path.cwd().resolve()
        config_path = base / "config.txt"
    else:
        config_path = Path(config_path).expanduser().resolve()

    config_dir = config_path.parent
    base = Path(tool_dir).resolve() if tool_dir is not None else config_dir

    merged = dict(DEFAULTS)
    merged.update(_read_values(config_path))
    override_keys = set(overrides or {})
    if overrides:
        for key, value in overrides.items():
            if key in DEFAULTS and value is not None:
                merged[key] = str(value)

    def origin_base(key: str) -> Path:
        return Path.cwd().resolve() if key in override_keys else config_dir

    def executable_value(key: str) -> str:
        value = merged[key].strip()
        if (
            key not in override_keys
            and value
            and _is_path_like(value)
            and not Path(value).expanduser().is_absolute()
        ):
            return str(config_dir / value)
        return value

    search_dirs = _search_dirs(base)
    ffmpeg = resolve_tool_path(
        executable_value("ffmpeg"),
        names=_names_for("ffmpeg"),
        search_dirs=search_dirs,
    )
    ffprobe = resolve_tool_path(
        executable_value("ffprobe"),
        names=_names_for("ffprobe"),
        search_dirs=search_dirs,
    )

    def optional_path(key: str) -> Path | None:
        value = merged[key].strip()
        if value.lower() == "auto" or not value:
            return None
        path = Path(value).expanduser()
        if not path.is_absolute():
            path = origin_base(key) / path
        return path.resolve()

    work_dir_value = Path(merged["work_dir"]).expanduser()
    if not work_dir_value.is_absolute():
        work_dir_value = origin_base("work_dir") / work_dir_value

    output_dir_value = Path(merged["output_dir"]).expanduser()
    if not output_dir_value.is_absolute():
        output_dir_value = origin_base("output_dir") / output_dir_value

    input_dir_value = Path(merged["input_dir"]).expanduser()
    if not input_dir_value.is_absolute():
        input_dir_value = origin_base("input_dir") / input_dir_value

    default_scale = _parse_int(merged["default_scale"], "default_scale")
    if default_scale not in {2, 3, 4}:
        raise ValidationError("default_scale must be 2, 3, or 4")

    default_preset = merged["default_preset"].strip()
    if default_preset not in _PRESETS:
        raise ValidationError(f"default_preset must be one of {sorted(_PRESETS)}")

    default_encoder = merged["default_encoder"].strip()
    if default_encoder not in _ENCODERS:
        raise ValidationError(f"default_encoder must be one of {sorted(_ENCODERS)}")

    default_audio = merged["default_audio"].strip()
    if default_audio not in _AUDIO_MODES:
        raise ValidationError(f"default_audio must be one of {sorted(_AUDIO_MODES)}")

    default_subs = merged["default_subs"].strip()
    if default_subs not in _SUBS_MODES:
        raise ValidationError(f"default_subs must be one of {sorted(_SUBS_MODES)}")

    tile = merged["tile"].strip() or "auto"
    if tile != "auto":
        tile_value = _parse_int(tile, "tile")
        if tile_value < 0:
            raise ValidationError("tile must be 'auto' or a non-negative integer")

    batch_size = _parse_int(merged["batch_size"], "batch_size")
    if batch_size <= 0:
        raise ValidationError("batch_size must be greater than zero")

    gpu = _parse_int(merged["gpu"], "gpu")
    if gpu < 0:
        raise ValidationError("gpu must be non-negative")

    max_work_gb = _parse_int(merged["max_work_gb"], "max_work_gb")
    if max_work_gb <= 0:
        raise ValidationError("max_work_gb must be greater than zero")

    min_free_gb = _parse_int(merged["min_free_gb"], "min_free_gb")
    if min_free_gb < 0:
        raise ValidationError("min_free_gb must be non-negative")

    return Config(
        ffmpeg=ffmpeg,
        ffprobe=ffprobe,
        upscayl_bin=optional_path("upscayl_bin"),
        models_dir=optional_path("models_dir"),
        work_dir=work_dir_value.resolve(),
        output_dir=output_dir_value.resolve(),
        input_dir=input_dir_value.resolve(),
        default_model=merged["default_model"].strip(),
        default_scale=default_scale,
        default_preset=default_preset,
        default_encoder=default_encoder,
        default_audio=default_audio,
        default_subs=default_subs,
        tile=tile,
        batch_size=batch_size,
        gpu=gpu,
        icd=merged["icd"].strip() or "auto",
        max_work_gb=max_work_gb,
        min_free_gb=min_free_gb,
        cleanup=_parse_bool(merged["cleanup"], "cleanup"),
        config_path=config_path,
        tool_dir=base,
    )
