"""Job folders and the shared job.txt contract."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Mapping

from .errors import ValidationError
from .probe import MediaInfo
from .util import Logger, atomic_write_text, read_text_utf8, sanitize_job_id


def read_kv(path: Path) -> dict[str, str]:
    path = Path(path)
    if not path.exists():
        return {}
    values: dict[str, str] = {}
    for line in read_text_utf8(path).splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def write_kv(path: Path, data: Mapping[str, str]) -> None:
    lines = [f"{key}={value}" for key, value in data.items()]
    atomic_write_text(Path(path), "\n".join(lines) + ("\n" if lines else ""))


def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _source_from_folder(path: Path) -> str | None:
    source_file = path / "source.txt"
    if source_file.is_file():
        value = read_text_utf8(source_file).strip()
        if value:
            return value
    job_file = path / "job.txt"
    if job_file.is_file():
        return read_kv(job_file).get("source")
    return None


def _same_source(folder: Path, source: Path) -> bool:
    existing = _source_from_folder(folder)
    if not existing:
        return False
    try:
        return Path(existing).expanduser().resolve() == source.resolve()
    except OSError:
        return False


@dataclass
class Job:
    path: Path
    data: dict[str, str] = field(default_factory=dict)

    @property
    def job_id(self) -> str:
        return self.path.name

    @property
    def source_path(self) -> Path:
        value = self.data.get("source")
        if not value:
            raise ValidationError(f"Job has no source path: {self.path}")
        return Path(value).expanduser()

    @property
    def frames_dir(self) -> Path:
        return self.path / "frames"

    @property
    def upscaled_dir(self) -> Path:
        return self.path / "upscaled"

    @property
    def chunks_dir(self) -> Path:
        return self.path / "chunks"

    @property
    def sequence_dir(self) -> Path:
        return self.path / "sequence"

    @property
    def output_dir(self) -> Path:
        return self.path / "output"

    @property
    def logs_dir(self) -> Path:
        return self.path / "logs"

    @classmethod
    def create_or_open(
        cls,
        work_dir: Path,
        source: Path,
        logger: Logger,
        *,
        create: bool = True,
    ) -> "Job":
        work_dir = Path(work_dir).expanduser().resolve()
        source = Path(source).expanduser().resolve()
        base_id = sanitize_job_id(source.stem)
        if create:
            work_dir.mkdir(parents=True, exist_ok=True)

        candidate = work_dir / base_id
        suffix = 2
        while candidate.exists():
            if candidate.is_dir() and _same_source(candidate, source):
                if (candidate / "job.txt").is_file():
                    job = cls.load(candidate)
                else:
                    job = cls(candidate, {"source": str(source)})
                job.write_source_file()
                logger.debug(f"Reusing job: {candidate}")
                return job
            candidate = work_dir / f"{base_id}_{suffix}"
            suffix += 1

        job = cls(
            candidate,
            {
                "version": "1",
                "job_id": candidate.name,
                "source": str(source),
                "created": _now(),
            },
        )
        if create:
            candidate.mkdir(parents=True, exist_ok=True)
            job.write_source_file()
            logger.debug(f"Created job: {candidate}")
        return job

    @classmethod
    def load(cls, path: Path) -> "Job":
        path = Path(path)
        job_file = path / "job.txt"
        if not path.is_dir() or not job_file.is_file():
            raise ValidationError(f"Not a job folder (missing job.txt): {path}")
        data = read_kv(job_file)
        if not data.get("source"):
            fallback = _source_from_folder(path)
            if fallback:
                data["source"] = fallback
            else:
                raise ValidationError(f"Job has no source path: {path}")
        return cls(path, data)

    def save(self) -> None:
        self.data["updated"] = _now()
        write_kv(self.path / "job.txt", self.data)
        self.write_source_file()

    def write_source_file(self) -> None:
        self.path.mkdir(parents=True, exist_ok=True)
        atomic_write_text(
            self.path / "source.txt",
            str(self.source_path.resolve()) + "\n",
        )

    def get(self, key: str, default: str | None = None) -> str | None:
        value = self.data.get(key)
        if value is None:
            return default
        return value

    def get_int(self, key: str, default: int = 0) -> int:
        raw = self.data.get(key)
        if raw is None or raw == "":
            return default
        try:
            return int(raw)
        except ValueError:
            return default

    def get_bool(self, key: str, default: bool = False) -> bool:
        raw = self.data.get(key)
        if raw is None or raw == "":
            return default
        return raw.strip().lower() in {"1", "true", "yes", "on"}

    def set(self, key: str, value: object) -> None:
        if isinstance(value, bool):
            self.data[key] = "1" if value else "0"
        else:
            self.data[key] = str(value)

    def mark_done(self, stage: str) -> None:
        marker = self.path / f".done_{stage}"
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text("", encoding="utf-8")

    def is_done(self, stage: str) -> bool:
        return (self.path / f".done_{stage}").is_file()

    def clear_stage(self, stage: str) -> None:
        marker = self.path / f".done_{stage}"
        if marker.exists():
            marker.unlink()

    def update_from_media(self, media: MediaInfo) -> None:
        self.set("source", str(Path(media.source).resolve()))
        self.set("source_size", media.source_size)
        self.set("source_mtime", media.source_mtime)
        self.set("source_duration", f"{media.duration:.3f}")
        self.set("duration", f"{media.duration:.3f}")
        self.set("fps", media.fps_rational)
        self.set("fps_decimal", f"{media.fps_decimal:.3f}")
        self.set("width", media.width)
        self.set("height", media.height)
        self.set("pix_fmt", media.pix_fmt)
        self.set("color_primaries", media.color_primaries or "unknown")
        self.set("color_trc", media.color_trc or "unknown")
        self.set("colorspace", media.colorspace or "unknown")
        self.set("color_range", media.color_range or "unknown")
        self.set("rotation", media.rotation)
        self.set("hdr", media.hdr)

    def source_changed(self) -> bool:
        if "source_size" not in self.data or "source_mtime" not in self.data:
            return True
        try:
            stat = self.source_path.stat()
        except OSError:
            return True
        return (
            int(self.data.get("source_size", "-1")) != stat.st_size
            or int(self.data.get("source_mtime", "-1")) != int(stat.st_mtime)
        )


def find_jobs(work_dir: Path) -> list[Job]:
    work_dir = Path(work_dir).expanduser().resolve()
    if not work_dir.is_dir():
        return []
    jobs: list[Job] = []
    for child in sorted(work_dir.iterdir(), key=lambda path: path.name.lower()):
        if not child.is_dir() or not (child / "job.txt").is_file():
            continue
        try:
            jobs.append(Job.load(child))
        except ValidationError:
            continue
    return jobs
