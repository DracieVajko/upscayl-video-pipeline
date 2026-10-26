# Upscayl Video Pipeline — V1 Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a working V1 Python CLI that splits one or more videos into frames, supports manual Upscayl GUI upscaling, and reassembles the frames into MP4/MKV/MOV with audio, subtitles, metadata, and GPU/CPU encoding.

**Architecture:** A stdlib-only Python package under `src/upscayl_video/` with focused modules for config, job metadata, probing, frame extraction, disk estimation, encoding, orchestration, doctor checks, and a basic menu. A thin root launcher exposes the CLI. Jobs use a shared `job.txt` key=value contract so later V1 automation and V2 native implementations can read the same work folders.

**Tech Stack:** Python 3.10+ (stdlib only), FFmpeg/ffprobe, `unittest`, PowerShell/bash launchers. No third-party Python packages, no network access.

**Spec:** `docs/specs/2026-10-26-upscayl-video-pipeline-design.md`

This is plan 1 of 4. It deliberately excludes automated `upscale`, `run`, chunking, and the full menu; those are plan 2. Plans 3 and 4 implement V2 Windows and Unix parity. Each plan produces working, testable software on its own.

---

## Global Constraints

- Python 3.10+ only; standard library only; no `pip install`, no network calls.
- English CLI messages, README, and docs.
- V1 runs on Windows, Linux, and macOS. Paths may contain spaces and Unicode.
- FFmpeg and ffprobe are required. Upscayl is optional in this plan; `split` and `assemble` must work without it.
- Never delete the source video. Never delete outside the job folder. `clean` requires explicit targets.
- `job.txt` and `config.txt` are UTF-8 key=value files, one pair per line, split on the first `=`, values may contain `=` and spaces, unknown keys are preserved, and writes are atomic.
- Frame numbering is 8 digits, starting at 1: `frame_00000001.png` or `.jpg`.
- Defaults: model `upscayl-standard-4x`, scale `2`, preset `mp4-h264`, quality `balanced`, encoder `auto`, audio `auto` (first track), subtitles `auto`.
- Output is CFR. VFR sources are converted to CFR at the probed average frame rate.
- HDR (PQ/HLG) is rejected by default; `--tonemap` at split time converts to SDR BT.709. 10-bit SDR is accepted and downconverted to 8-bit RGB with a warning.
- Validate the final output with ffprobe; exit codes are 0 OK, 1 general, 2 usage, 3 dependency, 4 validation, 5 disk, 6 upscale, 7 encode, 8 output validation, 130 interrupted.
- No `upscale`, `run`, chunking, or real Upscayl invocation in this plan. A basic menu is included.
- Commit after every task. Run the full test suite before each commit.

---

## Review Focus

These are the input classes most likely to break a real user's first run. Each one has a test pinned to the owning task.

1. **Windows paths with spaces and non-ASCII characters** — job folder names, `source.txt`, log paths, and every FFmpeg argument must survive. Tests: Tasks 1, 3, 7, 11, 15.
2. **Odd dimensions, rotation, and anamorphic sources** — pad to even dimensions, autorotate once, strip rotation metadata, do not silently change display aspect. Tests: Tasks 4, 5, 7, 10.
3. **Audio codec/container mismatch, no audio, and multiple tracks** — MP3 in MP4, PCM in MKV, AAC fallback, first-track default, `--all-audio`. Tests: Tasks 9, 11.
4. **Subtitle type/container mismatch** — text subtitles to `mov_text` in MP4, copy in MKV, image subtitles dropped with a warning, explicit `copy`/`convert` errors. Tests: Tasks 9, 11.
5. **Interrupted/partial frame sets, HDR/10-bit, and VFR sources** — resume extraction, reject HDR without tonemap, warn on 10-bit SDR, CFR conversion. Tests: Tasks 4, 5, 7.

---

## File Map

| Path | Responsibility |
|---|---|
| `upscayl-video.py` | Root launcher; adds `src/` to `sys.path`; calls `upscayl_video.cli.main()` |
| `upscayl-video.bat` | Windows launcher; UTF-8 code page; calls the Python launcher |
| `upscayl-video.sh` | Unix launcher; resolves its own directory; calls the Python launcher |
| `src/upscayl_video/__init__.py` | Version string |
| `src/upscayl_video/errors.py` | Exception hierarchy and exit codes |
| `src/upscayl_video/util.py` | Logger, subprocess runner, atomic writes, path/time/number helpers |
| `src/upscayl_video/config.py` | `config.txt` parsing, defaults, executable discovery |
| `src/upscayl_video/job.py` | Job creation/reuse, `job.txt`/`source.txt`, markers, job scanning |
| `src/upscayl_video/probe.py` | ffprobe JSON parsing, fps rationals, streams, chapters, color, HDR |
| `src/upscayl_video/frames.py` | Frame extraction, resume, counting, validation, manual-name matching, sequence normalization |
| `src/upscayl_video/disk.py` | Sample-frame estimate, free-space checks |
| `src/upscayl_video/encode.py` | Presets, encoder selection, audio/subtitle plans, assemble command, output validation |
| `src/upscayl_video/pipeline.py` | `split`, `assemble`, `status`, `clean` orchestration and input/job resolution |
| `src/upscayl_video/doctor.py` | Environment checks and table output |
| `src/upscayl_video/menu.py` | Basic interactive menu |
| `src/upscayl_video/cli.py` | argparse commands, exception-to-exit-code mapping |
| `tests/factories.py` | `MediaInfo`/`StreamInfo` test factories |
| `tests/util.py` | CLI invocation, ffprobe JSON helper, test clip generator |
| `tests/test_*.py` | Unit tests per module |
| `tests/integration/test_manual_workflow.py` | Split → manual Upscayl naming → assemble |
| `tests/fixtures/make_fixtures.py` | Generates test media with FFmpeg |
| `docs/USAGE.md` | Core command reference |
| `docs/TROUBLESHOOTING.md` | Core troubleshooting |
| `README.md` | Updated quick start |

---

### Task 1: Scaffold, errors, and utilities

**Files:**
- Create: `src/upscayl_video/__init__.py`
- Create: `src/upscayl_video/errors.py`
- Create: `src/upscayl_video/util.py`
- Create: `tests/__init__.py`
- Create: `tests/test_util.py`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `errors.PipelineError(message: str, hint: str | None = None)`, subclasses `UsageError` (2), `DependencyError` (3), `ValidationError` (4), `DiskSpaceError` (5), `UpscaleError` (6), `EncodeError` (7), `OutputValidationError` (8), `PipelineInterrupted` (130), `CommandError` (1, with `returncode`, `stderr_tail`).
  - `util.Logger(verbose: bool = False, quiet: bool = False, log_file: Path | None = None)` with `info`, `warn`, `error`, `debug`, `command`, and `set_log_file(path: Path | None) -> None`.
  - `util.run_command(args: Sequence[str], *, logger: Logger, env: Mapping[str,str] | None = None, cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]`.
  - `util.atomic_write_text(path: Path, text: str) -> None`, `util.read_text_utf8(path: Path) -> str`.
  - `util.parse_time(value: str) -> float`, `util.format_duration(seconds: float) -> str`.
  - `util.sanitize_job_id(stem: str) -> str`, `util.human_bytes(n: int) -> str`.
  - `util.ensure_within(path: Path, root: Path) -> Path`.

- [ ] **Step 1: Write the failing utility tests**

```python
# tests/test_util.py
import sys
import tempfile
import unittest
from pathlib import Path

from upscayl_video.errors import CommandError, ValidationError
from upscayl_video.util import (
    atomic_write_text,
    format_duration,
    human_bytes,
    parse_time,
    sanitize_job_id,
    run_command,
    Logger,
)


class TestTimeParsing(unittest.TestCase):
    def test_seconds(self):
        self.assertEqual(parse_time("90"), 90.0)

    def test_minutes_seconds(self):
        self.assertEqual(parse_time("1:30"), 90.0)

    def test_hours_minutes_seconds_with_fraction(self):
        self.assertEqual(parse_time("01:02:03.5"), 3723.5)

    def test_negative_is_rejected(self):
        with self.assertRaises(ValidationError):
            parse_time("-1")


class TestFormatting(unittest.TestCase):
    def test_format_duration(self):
        self.assertEqual(format_duration(3723.5), "01:02:03.500")

    def test_human_bytes(self):
        self.assertEqual(human_bytes(0), "0 B")
        self.assertEqual(human_bytes(1536), "1.5 KiB")
        self.assertEqual(human_bytes(10 * 1024 * 1024), "10.0 MiB")


class TestSanitizeJobId(unittest.TestCase):
    def test_windows_invalid_characters_and_spaces(self):
        self.assertEqual(sanitize_job_id("my video: final?"), "my_video_final")

    def test_unicode_is_preserved(self):
        self.assertEqual(sanitize_job_id("žluťoučký kůň"), "žluťoučký_kůň")

    def test_reserved_windows_name(self):
        self.assertEqual(sanitize_job_id("CON"), "CON_")

    def test_empty_falls_back(self):
        self.assertEqual(sanitize_job_id("  ...  "), "video")


class TestAtomicWrite(unittest.TestCase):
    def test_replaces_content_without_leaving_temp_file(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "job.txt"
            atomic_write_text(path, "a=1\n")
            atomic_write_text(path, "a=2\n")
            self.assertEqual(path.read_text(encoding="utf-8"), "a=2\n")
            self.assertEqual(list(Path(td).iterdir()), [path])


class TestRunCommand(unittest.TestCase):
    def test_captures_stdout(self):
        logger = Logger(quiet=True)
        result = run_command(
            [sys.executable, "-c", "print('hello')"],
            logger=logger,
        )
        self.assertEqual(result.stdout.strip(), "hello")

    def test_nonzero_raises_command_error(self):
        logger = Logger(quiet=True)
        with self.assertRaises(CommandError):
            run_command(
                [sys.executable, "-c", "import sys; sys.exit(7)"],
                logger=logger,
            )
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest tests.test_util -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'upscayl_video'` or missing functions.

- [ ] **Step 3: Implement the package, errors, and utilities**

Create `src/upscayl_video/__init__.py` with `__version__ = "0.1.0"`.

Create `errors.py` with the exception hierarchy. `PipelineError` stores `message`, `hint`, and class-level `exit_code`. `CommandError` stores `returncode` and `stderr_tail` (last 50 lines). `__str__` returns the message plus `\nHint: ...` when a hint exists.

Create `util.py`:
- `Logger` writes `YYYY-MM-DDTHH:MM:SS+ZZ:ZZ [LEVEL] message` to the log file when configured; console goes to stdout for info/debug and stderr for warn/error. `quiet` suppresses info/debug/warn but not errors. `set_log_file` creates the parent directory, switches the log target, and opens in append mode.
- `run_command` uses `subprocess.run(args, text=True, encoding="utf-8", errors="replace", stdin=subprocess.DEVNULL, capture_output=True, env=..., cwd=...)`. On `check=True` and nonzero, raise `CommandError` with the last 50 stderr lines.
- `atomic_write_text` writes to `path.with_name(path.name + ".tmp")` in the same directory, flushes, then `os.replace`.
- `read_text_utf8` reads with `utf-8-sig` so a BOM is tolerated.
- `parse_time` accepts `SS`, `MM:SS`, `HH:MM:SS`, optional `.mmm`; rejects negative and malformed values with `ValidationError`.
- `format_duration` returns `HH:MM:SS.mmm`.
- `sanitize_job_id`: replace `<>:"/\|?*` and control characters with `_`, replace whitespace runs with `_`, collapse `_`, strip `._ `, keep Unicode letters/digits/`._-`, append `_` for reserved Windows device names, truncate to 80 characters, fall back to `video`.
- `human_bytes` uses 1024-based units with one decimal for KiB/MiB/GiB/TiB.
- `ensure_within` resolves both paths and raises `ValidationError` if `path` is not inside `root`.

Add `src` to the import path for tests. Create `tests/__init__.py` and add a `sitecustomize`-free approach: each test imports `upscayl_video`, so run tests with `PYTHONPATH=src`. Add a `tests/__init__.py` that inserts `src` into `sys.path` only if needed? Better: create `tests/__init__.py` with a path bootstrap:

```python
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest tests.test_util -v`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/__init__.py src/upscayl_video/errors.py src/upscayl_video/util.py tests/__init__.py tests/test_util.py
git commit -m "feat: add package scaffold, errors, and utilities"
```

---

### Task 2: Configuration and executable discovery

**Files:**
- Create: `src/upscayl_video/config.py`
- Create: `tests/test_config.py`

**Interfaces:**
- Consumes: `errors.DependencyError`, `errors.ValidationError`, `util.read_text_utf8`, `util.which`-style helpers.
- Produces:
  - `config.Config` frozen dataclass with fields `ffmpeg: Path`, `ffprobe: Path`, `upscayl_bin: Path | None`, `models_dir: Path | None`, `work_dir: Path`, `default_model: str`, `default_scale: int`, `default_preset: str`, `default_encoder: str`, `default_audio: str`, `default_subs: str`, `tile: str`, `batch_size: int`, `gpu: int`, `icd: str`, `max_work_gb: int`, `min_free_gb: int`, `cleanup: bool`, `config_path: Path`, `tool_dir: Path`.
  - `config.load_config(config_path: Path | None = None, *, overrides: Mapping[str, str] | None = None, tool_dir: Path | None = None) -> Config`.
  - `config.DEFAULTS: dict[str, str]`.
  - `config.resolve_tool_path(value: str, *, names: Sequence[str], search_dirs: Sequence[Path]) -> Path`.

- [ ] **Step 1: Write the failing config tests**

```python
# tests/test_config.py
import sys
import tempfile
import unittest
from pathlib import Path

from upscayl_video.config import DEFAULTS, load_config
from upscayl_video.errors import DependencyError, ValidationError


FAKE_FFMPEG = Path(sys.executable)


class TestConfig(unittest.TestCase):
    def write_config(self, td: str, text: str) -> Path:
        path = Path(td) / "config.txt"
        path.write_text(text, encoding="utf-8")
        return path

    def test_defaults_are_loaded(self):
        with tempfile.TemporaryDirectory() as td:
            path = self.write_config(
                td,
                f"ffmpeg={FAKE_FFMPEG}\nffprobe={FAKE_FFMPEG}\n",
            )
            cfg = load_config(path)
            self.assertEqual(cfg.work_dir, path.parent / "work")
            self.assertEqual(cfg.default_preset, "mp4-h264")
            self.assertEqual(cfg.default_scale, 2)
            self.assertIsNone(cfg.upscayl_bin)

    def test_cli_overrides_win(self):
        with tempfile.TemporaryDirectory() as td:
            path = self.write_config(
                td,
                f"ffmpeg={FAKE_FFMPEG}\nffprobe={FAKE_FFMPEG}\ndefault_scale=2\n",
            )
            cfg = load_config(path, overrides={"default_scale": "4"})
            self.assertEqual(cfg.default_scale, 4)

    def test_invalid_scale_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            path = self.write_config(
                td,
                f"ffmpeg={FAKE_FFMPEG}\nffprobe={FAKE_FFMPEG}\ndefault_scale=5\n",
            )
            with self.assertRaises(ValidationError):
                load_config(path)

    def test_missing_executable_is_a_dependency_error(self):
        with tempfile.TemporaryDirectory() as td:
            path = self.write_config(
                td,
                f"ffmpeg={Path(td) / 'missing.exe'}\nffprobe={FAKE_FFMPEG}\n",
            )
            with self.assertRaises(DependencyError):
                load_config(path)

    def test_directory_value_finds_named_executable(self):
        with tempfile.TemporaryDirectory() as td:
            bindir = Path(td) / "bin"
            bindir.mkdir()
            name = "ffmpeg.exe" if sys.platform.startswith("win") else "ffmpeg"
            fake = bindir / name
            fake.write_text("", encoding="utf-8")
            path = self.write_config(
                td,
                f"ffmpeg={bindir}\nffprobe={FAKE_FFMPEG}\n",
            )
            cfg = load_config(path)
            self.assertEqual(cfg.ffmpeg, fake)

    def test_unknown_keys_are_ignored(self):
        with tempfile.TemporaryDirectory() as td:
            path = self.write_config(
                td,
                f"ffmpeg={FAKE_FFMPEG}\nffprobe={FAKE_FFMPEG}\nfuture_key=value\n",
            )
            cfg = load_config(path)
            self.assertEqual(cfg.default_model, DEFAULTS["default_model"])
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest tests.test_config -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'upscayl_video.config'`.

- [ ] **Step 3: Implement `config.py`**

- `DEFAULTS` contains every key from spec section 7.3 with the exact default values.
- `load_config` reads the file if it exists; missing file means defaults. Parse key=value lines, ignore blank lines and `#` comments, trim surrounding whitespace, ignore unknown keys.
- Resolve `work_dir` relative to the config file's directory. If `tool_dir` is given and no config file exists, use `tool_dir` as the base.
- Resolve `ffmpeg`/`ffprobe` in this order: explicit value, `PATH`, tool dir, tool dir's parent, common locations. If the value is a directory, look for `ffmpeg.exe`/`ffprobe.exe` (Windows) or `ffmpeg`/`ffprobe` (Unix). Raise `DependencyError` with all searched locations if not found.
- `upscayl_bin` and `models_dir` are `None` when the value is `auto`; otherwise resolve as a path if it exists, else keep the configured path (the upscale plan validates later).
- Validate: `default_scale in {2,3,4}`, `default_preset in {"mp4-h264","mp4-hevc","mkv-hevc","mov-prores"}`, `default_encoder in {"auto","nvidia","amd","cpu"}`, `default_audio in {"auto","copy","aac","pcm","none"}`, `default_subs in {"auto","copy","convert","none"}`, `batch_size > 0`, `max_work_gb > 0`, `min_free_gb >= 0`.
- Overrides are applied after file values and before validation.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest tests.test_config -v`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/config.py tests/test_config.py
git commit -m "feat: load config and discover ffmpeg"
```

---

### Task 3: Job model and shared `job.txt` contract

**Files:**
- Create: `src/upscayl_video/job.py`
- Create: `tests/factories.py`
- Create: `tests/test_job.py`

**Interfaces:**
- Consumes: `config.Config`, `errors.ValidationError`, `probe.MediaInfo`, `util.atomic_write_text`, `util.read_text_utf8`, `util.sanitize_job_id`.
- Produces:
  - `job.Job` with `.path: Path`, `.data: dict[str, str]`, properties `job_id`, `source_path`, `frames_dir`, `upscaled_dir`, `chunks_dir`, `sequence_dir`, `output_dir`, `logs_dir`.
  - `Job.create_or_open(work_dir: Path, source: Path, logger: Logger, *, create: bool = True) -> Job`.
  - `Job.load(path: Path) -> Job`, `Job.save() -> None`, `Job.get(key, default=None)`, `Job.get_int`, `Job.get_bool`, `Job.set(key, value)`, `Job.mark_done(stage)`, `Job.is_done(stage)`, `Job.clear_stage(stage)`, `Job.update_from_media(media: MediaInfo)`, `Job.source_changed() -> bool`, `Job.write_source_file()`.
  - `job.find_jobs(work_dir: Path) -> list[Job]`.
  - `job.read_kv(path: Path) -> dict[str, str]`, `job.write_kv(path: Path, data: Mapping[str, str]) -> None`.
  - `tests.factories.make_media_info(...) -> MediaInfo`.

- [ ] **Step 1: Write the failing job tests and factory**

```python
# tests/factories.py
from pathlib import Path

from upscayl_video.probe import MediaInfo, StreamInfo


def make_media_info(
    source: Path,
    *,
    duration: float = 5.0,
    fps_num: int = 30,
    fps_den: int = 1,
    width: int = 320,
    height: int = 240,
    pix_fmt: str = "yuv420p",
    audio: tuple[StreamInfo, ...] = (),
    subtitles: tuple[StreamInfo, ...] = (),
    chapters: int = 0,
    color_trc: str | None = "bt709",
    color_range: str | None = "tv",
    hdr: bool = False,
    rotation: int = 0,
) -> MediaInfo:
    exists = source.exists()
    return MediaInfo(
        source=source,
        duration=duration,
        fps_num=fps_num,
        fps_den=fps_den,
        width=width,
        height=height,
        pix_fmt=pix_fmt,
        video_index=0,
        audio=audio,
        subtitles=subtitles,
        chapters=chapters,
        color_primaries="bt709",
        color_trc=color_trc,
        colorspace="bt709",
        color_range=color_range,
        rotation=rotation,
        hdr=hdr,
        source_size=source.stat().st_size if exists else 0,
        source_mtime=int(source.stat().st_mtime) if exists else 0,
    )
```

```python
# tests/test_job.py
import tempfile
import time
import unittest
from pathlib import Path

from upscayl_video.errors import ValidationError
from upscayl_video.job import Job, find_jobs, read_kv, write_kv
from upscayl_video.util import Logger
from tests.factories import make_media_info


class TestKvFiles(unittest.TestCase):
    def test_round_trip_preserves_equals_and_spaces(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "job.txt"
            write_kv(path, {"source": "C:/a b/c=d.mp4", "scale": "2"})
            data = read_kv(path)
            self.assertEqual(data["source"], "C:/a b/c=d.mp4")
            self.assertEqual(data["scale"], "2")


class TestJob(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.work = Path(self.td.name) / "work"
        self.source = Path(self.td.name) / "my video.mp4"
        self.source.write_bytes(b"fake video")
        self.logger = Logger(quiet=True)

    def tearDown(self):
        self.td.cleanup()

    def test_create_and_reopen_same_source(self):
        first = Job.create_or_open(self.work, self.source, self.logger)
        first.update_from_media(make_media_info(self.source))
        first.save()
        second = Job.create_or_open(self.work, self.source, self.logger)
        self.assertEqual(first.path, second.path)
        self.assertEqual(second.get("source"), str(self.source.resolve()))

    def test_same_stem_from_other_directory_gets_suffix(self):
        other_dir = Path(self.td.name) / "other"
        other_dir.mkdir()
        other = other_dir / "my video.mp4"
        other.write_bytes(b"other")
        first = Job.create_or_open(self.work, self.source, self.logger)
        second = Job.create_or_open(self.work, other, self.logger)
        self.assertNotEqual(first.path, second.path)
        self.assertTrue(second.path.name.endswith("_2"))

    def test_unknown_keys_are_preserved(self):
        first = Job.create_or_open(self.work, self.source, self.logger)
        first.set("future_key", "value")
        first.save()
        first.set("scale", "2")
        first.save()
        self.assertEqual(Job.load(first.path).get("future_key"), "value")

    def test_markers(self):
        job = Job.create_or_open(self.work, self.source, self.logger)
        self.assertFalse(job.is_done("split"))
        job.mark_done("split")
        self.assertTrue(job.is_done("split"))
        job.clear_stage("split")
        self.assertFalse(job.is_done("split"))

    def test_source_changed(self):
        job = Job.create_or_open(self.work, self.source, self.logger)
        job.update_from_media(make_media_info(self.source))
        job.save()
        time.sleep(0.01)
        self.source.write_bytes(b"changed content")
        self.assertTrue(job.source_changed())

    def test_find_jobs(self):
        job = Job.create_or_open(self.work, self.source, self.logger)
        job.save()
        self.assertEqual([j.path for j in find_jobs(self.work)], [job.path])

    def test_invalid_job_folder_is_rejected(self):
        bad = Path(self.td.name) / "bad"
        bad.mkdir()
        with self.assertRaises(ValidationError):
            Job.load(bad)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest tests.test_job -v`
Expected: FAIL because `upscayl_video.job` and `upscayl_video.probe` do not exist yet. Task 4 creates `probe.py`; to keep this task independently testable, create a minimal `probe.py` with the `StreamInfo`/`MediaInfo` dataclasses and no ffprobe call in Task 3, then Task 4 adds `probe_media`. Adjust the file list: this task creates `src/upscayl_video/probe.py` with only the dataclasses. Task 4 modifies it.

- [ ] **Step 3: Implement `job.py` and the probe dataclasses**

- `read_kv`: read UTF-8 with BOM tolerance, split on first `=`, strip trailing `\r`, skip blank lines and lines starting with `#` (for job.txt there are no comments, but tolerate them). Preserve order in a normal dict.
- `write_kv`: write `key=value\n` lines in insertion order; atomic write.
- `Job.create_or_open`: resolve the work dir; sanitize the stem; candidate folder `<work>/<job_id>`; if it exists and `source.txt` or `job.txt:source` points to the same resolved source, reuse; otherwise append `_2`, `_3`, ...; if `create=False` and no folder exists, return an in-memory `Job` for the candidate path without creating anything; otherwise create the folder and `source.txt`. Do not create frames/upscaled until needed.
- If an existing folder has no `source.txt`/`job.txt`, append a suffix rather than reuse.
- `Job.load`: require a directory containing `job.txt`; raise `ValidationError` otherwise.
- `Job.save`: write `job.txt` atomically; update `updated` to the current local ISO timestamp; write `source.txt` with the source path.
- `Job.update_from_media`: set `source`, `source_size`, `source_mtime`, `source_duration`, `duration`, `fps`, `fps_decimal`, `width`, `height`, `pix_fmt`, `color_primaries`, `color_trc`, `colorspace`, `color_range`, `hdr`; do not overwrite user-selected `scale`, `model`, `preset`, etc.
- `source_changed`: compare current size/mtime with stored values.
- `mark_done`: create an empty `.done_<stage>` file. `clear_stage`: unlink it if present.
- `find_jobs`: sorted directories containing `job.txt`; ignore invalid ones and log at debug level.
- `probe.py` dataclasses: `StreamInfo(index, codec_name, channels=None, bit_rate=None, language=None, title=None)` and `MediaInfo` with the fields from the factory, properties `fps_decimal`, `fps_rational`, `has_audio`, `has_subtitles`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest tests.test_job -v`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/job.py src/upscayl_video/probe.py tests/factories.py tests/test_job.py
git commit -m "feat: add job folder and job.txt contract"
```

---

### Task 4: ffprobe parsing and media metadata

**Files:**
- Modify: `src/upscayl_video/probe.py`
- Create: `tests/data/ffprobe_sample.json`
- Create: `tests/test_probe.py`

**Interfaces:**
- Consumes: `errors.ValidationError`, `util.run_command`.
- Produces:
  - `probe.probe_media(ffprobe: Path, source: Path, logger: Logger) -> MediaInfo`.
  - `probe.media_info_from_json(source: Path, data: Mapping[str, object]) -> MediaInfo`.
  - `probe.parse_rational(value: str) -> tuple[int, int]`.
  - `probe.normalize_fps(avg: str | None, real: str | None) -> tuple[int, int]`.
  - `probe.is_hdr(color_trc: str | None, pix_fmt: str) -> bool`.

- [ ] **Step 1: Write the failing probe tests**

```python
# tests/test_probe.py
import json
import tempfile
import unittest
from pathlib import Path

from upscayl_video.errors import ValidationError
from upscayl_video.probe import (
    is_hdr,
    media_info_from_json,
    normalize_fps,
    parse_rational,
)


class TestFps(unittest.TestCase):
    def test_rational(self):
        self.assertEqual(parse_rational("30000/1001"), (30000, 1001))

    def test_invalid_falls_back(self):
        self.assertEqual(normalize_fps("0/0", "25/1"), (25, 1))

    def test_both_invalid_falls_back_to_30(self):
        self.assertEqual(normalize_fps("0/0", "0/0"), (30, 1))


class TestHdr(unittest.TestCase):
    def test_pq(self):
        self.assertTrue(is_hdr("smpte2084", "yuv420p10le"))

    def test_hlg(self):
        self.assertTrue(is_hdr("arib-std-b67", "yuv420p10le"))

    def test_sdr(self):
        self.assertFalse(is_hdr("bt709", "yuv420p"))


class TestMediaInfo(unittest.TestCase):
    def test_parses_streams_chapters_and_color(self):
        data = json.loads((Path(__file__).parent / "data" / "ffprobe_sample.json").read_text(encoding="utf-8"))
        source = Path("clip.mp4")
        info = media_info_from_json(source, data)
        self.assertAlmostEqual(info.duration, 5.0)
        self.assertEqual((info.fps_num, info.fps_den), (30, 1))
        self.assertEqual(info.width, 320)
        self.assertEqual(info.height, 240)
        self.assertEqual(len(info.audio), 1)
        self.assertEqual(info.audio[0].codec_name, "aac")
        self.assertEqual(len(info.subtitles), 1)
        self.assertEqual(info.subtitles[0].codec_name, "subrip")
        self.assertEqual(info.chapters, 1)
        self.assertEqual(info.color_primaries, "bt709")
        self.assertFalse(info.hdr)
        self.assertEqual(info.rotation, 0)

    def test_missing_video_stream_is_rejected(self):
        data = {"format": {"duration": "5.0"}, "streams": [{"codec_type": "audio", "codec_name": "aac"}]}
        with self.assertRaises(ValidationError):
            media_info_from_json(Path("clip.mp4"), data)
```

Create `tests/data/ffprobe_sample.json` with a realistic ffprobe JSON: one H.264 video stream (`avg_frame_rate` `30/1`, 320×240, `pix_fmt` `yuv420p`, color tags), one AAC audio stream, one subrip subtitle stream, one chapter, and a `format.duration` of `5.0`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest tests.test_probe -v`
Expected: FAIL because `probe_media`, `media_info_from_json`, `normalize_fps`, and `is_hdr` are missing.

- [ ] **Step 3: Implement probing**

- `parse_rational`: split on `/`, parse positive ints; on failure return `(0, 0)`.
- `normalize_fps`: use `avg` if valid and non-zero, else `real`, else `(30, 1)`. Reduce the fraction with `math.gcd`; guard against zero denominator.
- `is_hdr`: true for `smpte2084` or `arib-std-b67`; also true for 10/12/16-bit pixel formats when the transfer is PQ/HLG. Do not treat every 10-bit SDR source as HDR; the caller handles 10-bit SDR separately.
- `media_info_from_json`:
  - `format.duration` → float; fall back to the video stream duration.
  - first `codec_type == "video"` stream; if none, raise `ValidationError`.
  - `avg_frame_rate`/`r_frame_rate` → fps rational.
  - width/height/pix_fmt.
  - audio streams: index, codec_name, channels, bit_rate, tags.language, tags.title.
  - subtitle streams: same shape.
  - chapters: length of `data.get("chapters", [])`.
  - color tags from the video stream; normalize `"unknown"` to `None`.
  - rotation: `side_data_list` entry with `rotation`, else `tags.rotate`; store `int(value) % 360`.
  - HDR: `is_hdr(color_trc, pix_fmt)`.
  - source size/mtime from `source.stat()`; if the file does not exist (unit tests), use 0.
- `probe_media`: run `ffprobe -v error -print_format json -show_format -show_streams -show_chapters <source>`, parse JSON, call `media_info_from_json`. On failure, raise `ValidationError` with the ffprobe stderr tail.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest tests.test_probe -v`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/probe.py tests/data/ffprobe_sample.json tests/test_probe.py
git commit -m "feat: parse ffprobe metadata"
```

---

### Task 5: Frame extraction, resume, matching, and normalization

**Files:**
- Create: `src/upscayl_video/frames.py`
- Create: `tests/test_frames.py`
- Create: `tests/integration/__init__.py`
- Create: `tests/integration/test_frames_extract.py`

**Interfaces:**
- Consumes: `config.Config`, `job.Job`, `probe.MediaInfo`, `util.run_command`, `util.ValidationError`.
- Produces:
  - `frames.FrameSet(directory: Path, extension: str, indices: tuple[int, ...], paths: tuple[Path, ...])` with `count`, `first_index`, `last_index`, `is_normalized`.
  - `frames.frame_pattern(fmt: str) -> str`.
  - `frames.count_contiguous_frames(directory: Path, extension: str) -> int`.
  - `frames.scan_frames(directory: Path, *, recursive: bool = False) -> dict[int, list[Path]]`.
  - `frames.validate_frame_set(directory: Path, *, expected: int | None, pick: str = "error", verify: bool = False) -> FrameSet`.
  - `frames.check_frame_signature(path: Path) -> bool`.
  - `frames.build_sequence(frame_set: FrameSet, job: Job, logger: Logger) -> FrameSet`.
  - `frames.choose_decode(source: Path, media: MediaInfo, config: Config, logger: Logger) -> str`.
  - `frames.build_split_command(source: Path, job: Job, media: MediaInfo, *, start: float, duration: float | None, first_frame: int, fmt: str, jpeg_quality: int, png_compression: int, denoise: str, tonemap: bool, decode: str, output_dir: Path | None = None, frame_limit: int | None = None) -> list[str]`.
  - `frames.extract_frames(job: Job, media: MediaInfo, config: Config, *, fmt: str, jpeg_quality: int, png_compression: int, denoise: str, tonemap: bool, decode: str, start: float, end: float | None, verify: bool, logger: Logger, dry_run: bool = False) -> int`.

- [ ] **Step 1: Write the failing frame tests**

```python
# tests/test_frames.py
import tempfile
import unittest
from pathlib import Path

from upscayl_video.errors import ValidationError
from upscayl_video.frames import (
    build_sequence,
    check_frame_signature,
    count_contiguous_frames,
    frame_pattern,
    scan_frames,
    validate_frame_set,
)
from upscayl_video.job import Job
from upscayl_video.util import Logger
from tests.factories import make_media_info


class TestPatterns(unittest.TestCase):
    def test_png_pattern(self):
        self.assertEqual(frame_pattern("png"), "frame_%08d.png")

    def test_jpg_pattern(self):
        self.assertEqual(frame_pattern("jpg"), "frame_%08d.jpg")


class TestScanning(unittest.TestCase):
    def test_contiguous_count_stops_at_gap(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            for i in (1, 2, 4):
                (d / f"frame_{i:08d}.png").write_bytes(b"x")
            self.assertEqual(count_contiguous_frames(d, "png"), 2)

    def test_scan_matches_gui_suffix_and_subdir(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            sub = d / "upscayl_png_model_2x"
            sub.mkdir()
            (d / "frame_00000001.png").write_bytes(b"x")
            (sub / "frame_00000002_upscayl_4x_model.png").write_bytes(b"y")
            frames = scan_frames(d, recursive=True)
            self.assertEqual(sorted(frames), [1, 2])

    def test_duplicate_indices_are_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            (d / "frame_00000001.png").write_bytes(b"a")
            (d / "frame_00000001_upscayl.png").write_bytes(b"b")
            with self.assertRaises(ValidationError):
                validate_frame_set(d, expected=1)

    def test_missing_index_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            (d / "frame_00000001.png").write_bytes(b"a")
            (d / "frame_00000003.png").write_bytes(b"c")
            with self.assertRaises(ValidationError):
                validate_frame_set(d, expected=3)

    def test_signature(self):
        with tempfile.TemporaryDirectory() as td:
            png = Path(td) / "a.png"
            png.write_bytes(b"\x89PNG\r\n\x1a\n" + b"rest")
            jpg = Path(td) / "a.jpg"
            jpg.write_bytes(b"\xff\xd8\xff" + b"rest")
            self.assertTrue(check_frame_signature(png))
            self.assertTrue(check_frame_signature(jpg))
            self.assertFalse(check_frame_signature(Path(td) / "a.txt"))


class TestSequence(unittest.TestCase):
    def test_sequence_normalizes_suffixed_names(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            job_dir = root / "job"
            job_dir.mkdir()
            (job_dir / "job.txt").write_text("source=x\n", encoding="utf-8")
            src = root / "upscaled"
            src.mkdir()
            (src / "frame_00000001_upscayl_4x_model.png").write_bytes(b"a")
            (src / "frame_00000002_upscayl_4x_model.png").write_bytes(b"b")
            job = Job.load(job_dir)
            frame_set = validate_frame_set(src, expected=2)
            normalized = build_sequence(frame_set, job, Logger(quiet=True))
            self.assertEqual(normalized.paths[0].name, "frame_00000001.png")
            self.assertEqual(normalized.count, 2)


if __name__ == "__main__":
    unittest.main()
```

```python
# tests/integration/test_frames_extract.py
import tempfile
import unittest
from pathlib import Path

from upscayl_video.config import load_config
from upscayl_video.frames import count_contiguous_frames, extract_frames
from upscayl_video.job import Job
from upscayl_video.probe import probe_media
from upscayl_video.util import Logger
from tests.util import find_ffmpeg, find_ffprobe, make_clip


class TestExtractIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = find_ffmpeg()
        if cls.ffmpeg is None:
            raise unittest.SkipTest("ffmpeg not available")
        cls.ffprobe = find_ffprobe(cls.ffmpeg)
        cls.td = tempfile.TemporaryDirectory()
        cls.root = Path(cls.td.name)
        cls.clip = cls.root / "clip.mp4"
        make_clip(cls.ffmpeg, cls.clip, duration=1.0, size="160x120", fps=30)

    @classmethod
    def tearDownClass(cls):
        cls.td.cleanup()

    def test_extract_and_resume(self):
        work = self.root / "work"
        logger = Logger(quiet=True)
        source = self.clip
        media = probe_media(Path(self.ffprobe), source, logger)
        job = Job.create_or_open(work, source, logger)
        job.update_from_media(media)
        job.save()
        config = load_config(
            None,
            overrides={
                "ffmpeg": self.ffmpeg,
                "ffprobe": self.ffprobe,
                "work_dir": str(work),
            },
        )
        count = extract_frames(
            job, media, config, fmt="png", jpeg_quality=1, png_compression=3,
            denoise="none", tonemap=False, decode="cpu", start=0.0, end=None,
            verify=True, logger=logger,
        )
        self.assertEqual(count, 30)
        # Delete the last 5 frames and resume.
        for i in range(26, 31):
            (job.frames_dir / f"frame_{i:08d}.png").unlink()
        count2 = extract_frames(
            job, media, config, fmt="png", jpeg_quality=1, png_compression=3,
            denoise="none", tonemap=False, decode="cpu", start=0.0, end=None,
            verify=True, logger=logger,
        )
        self.assertEqual(count2, 30)
```

Create `tests/util.py` in this task with:
- `find_ffmpeg() -> str | None` using `shutil.which` and common paths.
- `find_ffprobe(ffmpeg: str) -> str`: sibling `ffprobe.exe` on Windows or `ffprobe` otherwise; fall back to `shutil.which("ffprobe")`; raise `unittest.SkipTest` if missing.
- `make_clip(ffmpeg: str, path: Path, *, duration: float, size: str, fps: int, audio: bool = True, video_codec: str = "libx264")` using lavfi `testsrc2` and `sine`. Pass `-frames:v round(duration * fps)` so the frame count is exact, and `-t <duration>` for the audio.
- `ffprobe_json(ffprobe: str, path: Path) -> dict`: run `ffprobe -v error -print_format json -show_format -show_streams` and parse JSON.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest tests.test_frames -v`
Expected: FAIL because `frames.py` is missing.

- [ ] **Step 3: Implement `frames.py`**

- `frame_pattern`: `frame_%08d.<ext>`; reject anything other than `png`/`jpg` with `ValidationError`.
- `scan_frames`: compile `^frame_(\d{8})(?:[_\-.].*)?\.(png|jpe?g|webp)$` case-insensitively. Scan the directory top level, plus one level of subdirectories when `recursive=True`. Group by index in a dict; ignore zero-byte files at validation time.
- `check_frame_signature`: PNG magic `\x89PNG\r\n\x1a\n`; JPEG `\xff\xd8\xff`; WebP starts with `RIFF` at bytes 0–3 and `WEBP` at bytes 8–11; otherwise false.
- `validate_frame_set`: remove zero-byte paths; if any index has more than one path, apply `pick`: `error` → `ValidationError` listing the paths; `newest` → max `st_mtime`; `largest` → max `st_size`. Require contiguous indices `1..N` (if `expected` is given, require N == expected and list missing indices). Require one common extension; mixed extensions → `ValidationError`. Verify signatures when requested. Return a `FrameSet` with sorted indices/paths.
- `count_contiguous_frames`: use `scan_frames` (non-recursive) and count indices from 1 until a gap.
- `build_sequence`: create `job.sequence_dir`; if the frame set is already normalized (`paths[i].name == frame_%08d.<ext>`), return it. Otherwise hardlink each path to `sequence/frame_%08d.<ext>`; on `OSError`, `shutil.copy2`. Return a normalized `FrameSet`. Never overwrite an existing sequence file silently; remove stale sequence dir first if it contains a different count (log a warning).
- `build_split_command`: start with `ffmpeg -hide_banner -nostdin -y -benchmark`. Add `-ss <start>` before `-i` when `start > 0`. Add `-i <source>`. Add `-t <duration>` when `duration` is not None. Add `-map 0:v:0 -an -sn -dn -fps_mode cfr -r <fps_num/fps_den> -start_number <first_frame>`. Add `-frames:v <frame_limit>` when `frame_limit` is not None. Build filters in order: tonemap chain if requested, denoise if not `none`, pad if width or height odd, `format=rgb24` for PNG or `format=yuvj420p` for JPEG. Add `-compression_level <n>` or `-q:v <n>`. Add the output pattern under `output_dir` (default `job.frames_dir`). Add `-hwaccel cuda|d3d11va|vaapi|videotoolbox` before `-i` when decode is `gpu`; choose based on platform and availability (NVIDIA first on Windows if `nvidia-smi` succeeds; otherwise `d3d11va` on Windows, `vaapi` on Linux, `videotoolbox` on macOS).
- `choose_decode`: if requested `cpu`, return `cpu`; if `gpu`, return `gpu` (extraction will fall back on failure); if `auto`, run a 30-frame benchmark with CPU and GPU to temporary dirs using `-benchmark`, parse the last `bench: rtime=...` from stderr, choose the lower; if the GPU command fails, return `cpu`. Log the chosen path and times.
- `extract_frames`: determine the processed duration from `media.duration`, `start`, `end`; compute expected frames as `round(duration * fps)`. If `decode == "auto"`, call `choose_decode` and use the result; store it in `job.set("decode", chosen)`. Count existing files and the contiguous prefix. If the file count is greater than the contiguous prefix, raise `ValidationError` (non-contiguous frames; suggest `--force`). If the contiguous prefix is > 0, resume at `first_frame = existing + 1` and `start = start + existing / fps`; do not resume if `existing == expected`. Build the command; run it unless `dry_run`; if a `gpu` decode command fails, log the failure and retry once with `cpu`; count/validate the final set; return the count. On ffmpeg failure, raise `EncodeError` with the log hint. If `tonemap` and `media.hdr` is false, warn but allow. If `media.hdr` is true and `tonemap` is false, raise `ValidationError` before extraction.
- Ensure the frames directory exists before running.
- For `--verify-frames`, validate signatures after extraction; otherwise check size > 0 and contiguous count.

- [ ] **Step 4: Run the tests to verify they pass**

Run:
- `python -m unittest tests.test_frames -v`
- `python -m unittest tests.integration.test_frames_extract -v`

Expected: all tests PASS. If ffmpeg is not available, the integration test skips with a clear message.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/frames.py tests/test_frames.py tests/integration/__init__.py tests/integration/test_frames_extract.py tests/util.py
git commit -m "feat: extract and validate video frames"
```

---

### Task 6: Disk estimation and free-space checks

**Files:**
- Create: `src/upscayl_video/disk.py`
- Create: `tests/test_disk.py`

**Interfaces:**
- Consumes: `config.Config`, `job.Job`, `probe.MediaInfo`, `frames.build_split_command`, `util.run_command`.
- Produces:
  - `disk.DiskEstimate(frame_bytes: int, frame_count: int, frames_bytes: int, upscaled_bytes: int, total_bytes: int, free_bytes: int, fits: bool)`.
  - `disk.free_bytes(path: Path) -> int`.
  - `disk.estimate_disk(sample_bytes: int, frame_count: int, scale: int, *, margin_bytes: int = 1024**3) -> DiskEstimate`.
  - `disk.check_estimate(estimate: DiskEstimate, *, min_free_gb: int, max_work_gb: int, logger: Logger) -> None`.
  - `disk.sample_frame_bytes(source: Path, job: Job, media: MediaInfo, config: Config, *, fmt: str, denoise: str, tonemap: bool, decode: str, logger: Logger, start: float = 0.0, duration: float | None = None) -> int`.

- [ ] **Step 1: Write the failing disk tests**

```python
# tests/test_disk.py
import tempfile
import unittest
from pathlib import Path

from upscayl_video.disk import DiskEstimate, check_estimate, estimate_disk, free_bytes
from upscayl_video.errors import DiskSpaceError
from upscayl_video.util import Logger


class TestEstimate(unittest.TestCase):
    def test_math(self):
        est = estimate_disk(1000, 100, 2, margin_bytes=0)
        self.assertEqual(est.frames_bytes, 115000)
        self.assertEqual(est.upscaled_bytes, 460000)
        self.assertEqual(est.total_bytes, 575000)

    def test_free_space_check(self):
        with tempfile.TemporaryDirectory() as td:
            self.assertGreater(free_bytes(Path(td)), 0)

    def test_min_free_floor_raises(self):
        est = DiskEstimate(1000, 100, 100, 100, 200, free_bytes=5 * 1024**3 + 100, fits=True)
        with self.assertRaises(DiskSpaceError):
            check_estimate(est, min_free_gb=5, max_work_gb=40, logger=Logger(quiet=True))

    def test_over_cap_only_warns(self):
        est = DiskEstimate(1000, 100, 100, 100, 50 * 1024**3, free_bytes=100 * 1024**3, fits=True)
        # Does not raise; the logger warning is not asserted here.
        check_estimate(est, min_free_gb=5, max_work_gb=40, logger=Logger(quiet=True))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest tests.test_disk -v`
Expected: FAIL because `disk.py` is missing.

- [ ] **Step 3: Implement `disk.py`**

- `free_bytes`: `shutil.disk_usage(path).free`; if the path does not exist, use the nearest existing parent.
- `estimate_disk`: `frames_bytes = sample_bytes * frame_count * 1.15`; `upscaled_bytes = sample_bytes * scale**2 * frame_count * 1.15`; `total = frames + upscaled + margin`; `fits = free >= total + min_free_gb` is computed by `check_estimate`, so set `fits=True` here or compute against `free_bytes` only. Define `fits = total_bytes <= free_bytes`; `check_estimate` uses `free_bytes - total_bytes >= min_free_gb`.
- `check_estimate`: if `estimate.total_bytes > max_work_gb * 1024**3`, `logger.warn(...)` with the chunking recommendation (chunking is plan 2). If `estimate.free_bytes - estimate.total_bytes < min_free_gb * 1024**3`, raise `DiskSpaceError` with a hint to use `--work-dir` on a larger drive or reduce the range.
- `sample_frame_bytes`: extract one frame at `start + min(1.0, duration * 0.1)` (or `start` when the duration is tiny) to a **system temporary directory** (not `job.path`, so `--dry-run` creates nothing), using the same filters as split, then return its size. Use `build_split_command` with `first_frame=1`, `duration=None`, `frame_limit=1`, and `output_dir=<temp dir>`; delete the temp directory afterward. If extraction fails, return a conservative default: `width * height * 3` bytes for PNG, `width * height` for JPEG. Log a warning.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest tests.test_disk -v`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/disk.py tests/test_disk.py
git commit -m "feat: estimate frame disk usage"
```

---

### Task 7: `split` pipeline and CLI

**Files:**
- Create: `src/upscayl_video/pipeline.py`
- Create: `src/upscayl_video/cli.py`
- Create: `upscayl-video.py`
- Create: `tests/test_pipeline_split.py`
- Create: `tests/test_cli.py`

**Interfaces:**
- Consumes: all prior modules.
- Produces:
  - `pipeline.SplitOptions(fps: str | None, start: str | None, end: str | None, format: str, jpeg_quality: int, png_compression: int, denoise: str, tonemap: bool, decode: str, scale: int | None, target_height: int | None, model: str, verify_frames: bool, recursive: bool, force: bool)`.
  - `pipeline.resolve_inputs(args: Sequence[str], config: Config, *, recursive: bool) -> list[Path]`.
  - `pipeline.run_split(inputs: Sequence[Path], config: Config, options: SplitOptions, logger: Logger, *, dry_run: bool = False, assume_yes: bool = False) -> list[Job]`.
  - `cli.main(argv: Sequence[str] | None = None) -> int`.

- [ ] **Step 1: Write the failing split tests**

```python
# tests/test_pipeline_split.py
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.config import load_config
from upscayl_video.errors import DiskSpaceError, ValidationError
from upscayl_video.pipeline import SplitOptions, resolve_inputs, run_split
from upscayl_video.util import Logger
from tests.factories import make_media_info
from tests.util import find_ffmpeg, find_ffprobe, make_clip


class TestResolveInputs(unittest.TestCase):
    def test_scans_directory_and_skips_outputs(self):
        ffmpeg = find_ffmpeg()
        if ffmpeg is None:
            self.skipTest("ffmpeg not available")
        ffprobe = find_ffprobe(ffmpeg)
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "a.mp4").write_bytes(b"a")
            (root / "b.MKV").write_bytes(b"b")
            (root / "note.txt").write_text("x", encoding="utf-8")
            (root / "a_upscaled.mp4").write_bytes(b"c")
            cfg = load_config(None, overrides={"ffmpeg": ffmpeg, "ffprobe": ffprobe})
            inputs = resolve_inputs([str(root)], cfg, recursive=False)
            self.assertEqual([p.name for p in inputs], ["a.mp4", "b.MKV"])


class TestSplit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = find_ffmpeg()
        if cls.ffmpeg is None:
            raise unittest.SkipTest("ffmpeg not available")
        cls.ffprobe = find_ffprobe(cls.ffmpeg)
        cls.td = tempfile.TemporaryDirectory()
        cls.root = Path(cls.td.name)
        cls.clip = cls.root / "clip.mp4"
        make_clip(cls.ffmpeg, cls.clip, duration=1.0, size="160x120", fps=30)

    @classmethod
    def tearDownClass(cls):
        cls.td.cleanup()

    def test_split_creates_job_and_frames(self):
        cfg = load_config(None, overrides={"ffmpeg": self.ffmpeg, "ffprobe": self.ffprobe, "work_dir": str(self.root / "work")})
        options = SplitOptions(
            fps=None, start=None, end=None, format="png", jpeg_quality=1,
            png_compression=3, denoise="none", tonemap=False, decode="cpu",
            scale=2, target_height=None, model="upscayl-standard-4x",
            verify_frames=True, recursive=False, force=False,
        )
        jobs = run_split([self.clip], cfg, options, Logger(quiet=True))
        self.assertEqual(len(jobs), 1)
        self.assertEqual(jobs[0].get_int("frame_count"), 30)
        self.assertTrue(jobs[0].is_done("split"))
        self.assertTrue((jobs[0].frames_dir / "frame_00000001.png").exists())

    def test_dry_run_creates_no_job(self):
        work = self.root / "dry-work"
        cfg = load_config(None, overrides={"ffmpeg": self.ffmpeg, "ffprobe": self.ffprobe, "work_dir": str(work)})
        jobs = run_split(
            [self.clip], cfg,
            SplitOptions(
                fps=None, start=None, end=None, format="png", jpeg_quality=1,
                png_compression=3, denoise="none", tonemap=False, decode="cpu",
                scale=2, target_height=None, model="upscayl-standard-4x",
                verify_frames=False, recursive=False, force=False,
            ),
            Logger(quiet=True),
            dry_run=True,
        )
        self.assertEqual(jobs, [])
        self.assertFalse(work.exists())

    def test_hdr_without_tonemap_is_rejected(self):
        cfg = load_config(None, overrides={"ffmpeg": self.ffmpeg, "ffprobe": self.ffprobe, "work_dir": str(self.root / "work2")})
        media = make_media_info(self.clip, hdr=True, color_trc="smpte2084")
        with patch("upscayl_video.pipeline.probe_media", return_value=media):
            with self.assertRaises(ValidationError):
                run_split([self.clip], cfg, SplitOptions(
                    fps=None, start=None, end=None, format="png", jpeg_quality=1,
                    png_compression=3, denoise="none", tonemap=False, decode="cpu",
                    scale=2, target_height=None, model="upscayl-standard-4x",
                    verify_frames=False, recursive=False, force=False,
                ), Logger(quiet=True))

    def test_hdr_with_tonemap_is_allowed(self):
        cfg = load_config(None, overrides={"ffmpeg": self.ffmpeg, "ffprobe": self.ffprobe, "work_dir": str(self.root / "work-tm")})
        media = make_media_info(self.clip, hdr=True, color_trc="smpte2084")
        with patch("upscayl_video.pipeline.probe_media", return_value=media), \
             patch("upscayl_video.pipeline.sample_frame_bytes", return_value=1000):
            jobs = run_split(
                [self.clip], cfg,
                SplitOptions(
                    fps=None, start=None, end=None, format="png", jpeg_quality=1,
                    png_compression=3, denoise="none", tonemap=True, decode="cpu",
                    scale=2, target_height=None, model="upscayl-standard-4x",
                    verify_frames=False, recursive=False, force=False,
                ),
                Logger(quiet=True),
                dry_run=True,
            )
        self.assertEqual(jobs, [])

    def test_low_disk_is_rejected(self):
        cfg = load_config(None, overrides={"ffmpeg": self.ffmpeg, "ffprobe": self.ffprobe, "work_dir": str(self.root / "work3")})
        with patch("upscayl_video.pipeline.sample_frame_bytes", return_value=10**9):
            with patch("upscayl_video.pipeline.free_bytes", return_value=10**8):
                with self.assertRaises(DiskSpaceError):
                    run_split([self.clip], cfg, SplitOptions(
                        fps=None, start=None, end=None, format="png", jpeg_quality=1,
                        png_compression=3, denoise="none", tonemap=False, decode="cpu",
                        scale=2, target_height=None, model="upscayl-standard-4x",
                        verify_frames=False, recursive=False, force=False,
                    ), Logger(quiet=True))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest tests.test_pipeline_split -v`
Expected: FAIL because `pipeline.py`/`cli.py` are missing.

- [ ] **Step 3: Implement `pipeline.run_split` and the `split` CLI**

- `resolve_inputs`: expand files, directories (top level or recursive), skip hidden files, `_upscaled.*`, non-video extensions, and anything under `config.work_dir`. Deduplicate by resolved path; sort by name. If no inputs and `<tool>/input` exists, scan it; otherwise raise `UsageError`.
- `run_split` for each input:
  1. `probe_media`.
  2. Apply the `--fps` override before creating the job: parse a decimal or rational, then replace the fps fields with `dataclasses.replace(media, fps_num=..., fps_den=...)` so the job, extraction, and later assembly all use the override.
  3. `Job.create_or_open(..., create=not dry_run)`; when not dry-run, point the logger at `job.logs_dir / "split.log"`. If an existing job has `frame_count > 0` and any split setting differs (format, fps, start, end, denoise, tonemap, compression/quality) and `force` is false, raise `ValidationError` listing the differences. If `force`, clear `frames/`, `upscaled/`, `sequence/`, `.done_split`, `.done_upscale`, and `.done_assemble` after a confirmation unless `assume_yes`.
  4. Compute processed `start`/`end`/`duration`; validate `start < end <= source_duration`.
  5. Choose the scale: if neither `--scale` nor `--target-height` is set, use `config.default_scale`. If `target_height` is set and `scale` is `None`, pick the smallest of 2/3/4 with `height * scale >= target_height`; if `target_height <= height`, raise `ValidationError`; if `height * scale > target_height`, record the target for assemble. If both are set, use the explicit scale and require `height * scale >= target_height`.
  6. HDR: if `media.hdr` and not `tonemap`, raise `ValidationError` with the exact explanation from the spec. If `media` is 10-bit SDR (`pix_fmt` contains `10`, `12`, or `16`) and not HDR, warn that frames are converted to 8-bit RGB for Upscayl. `--ten_bit` is an assemble-time check, not a split option.
  7. Update job metadata from the (possibly fps-overridden) media and the split options; set `duration` to the processed range duration, `range_start`, `range_end`, `scale`, `target_height`, `model`, `frame_format`, `denoise`, `decode`, `tonemap`; save unless `dry_run`.
  8. Sample one frame (`start=processed_start`, `duration=processed_duration`), estimate disk, check free space. If `dry_run`, print the estimate and return an empty list without creating a job folder, frames, or markers.
  9. `extract_frames`.
  10. Update `frame_count`, `upscaled_count=0`, save, mark `.done_split`.
- `cli.py`: build an argparse parser with `split` only for this task. Global options `--work-dir`, `--config`, `--ffmpeg`, `--ffprobe`, `--verbose`, `--quiet`, `--yes`, `--force`, `--dry-run`, `--version`. Split options from the spec. `main` loads the config with `tool_dir=Path(__file__).resolve().parents[2]` so the default work dir is the project root. `main` catches `PipelineError` and `KeyboardInterrupt`, prints the message/hint, returns the exit code. Add `--version` printing `upscayl-video 0.1.0`.
- Use a parent parser for the global options and pass it to each subparser with `parents=[global_parent]`, `add_help=False`. Give the parent clone defaults of `argparse.SUPPRESS` so values set before the subcommand are not overwritten. This makes `--work-dir` work both before and after `split`, matching the spec examples.
- `upscayl-video.py` root launcher: insert `src` into `sys.path`, import `main`, `sys.exit(main())`.
- Tests for CLI: `python upscayl-video.py --version` exits 0 and prints the version; `split --help` exits 0; a split command on a generated clip exits 0.

- [ ] **Step 4: Run the tests to verify they pass**

Run:
- `python -m unittest tests.test_pipeline_split -v`
- `python -m unittest tests.test_cli -v`
- `python upscayl-video.py split --help`

Expected: all PASS; help prints the split options.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/pipeline.py src/upscayl_video/cli.py upscayl-video.py tests/test_pipeline_split.py tests/test_cli.py
git commit -m "feat: add split pipeline and CLI"
```

---

### Task 8: Presets, quality mapping, and encoder selection

**Files:**
- Create: `src/upscayl_video/encode.py`
- Create: `tests/test_encode_presets.py`

**Interfaces:**
- Consumes: `config.Config`, `probe.MediaInfo`, `util.run_command`, `errors.DependencyError`, `errors.ValidationError`.
- Produces:
  - `encode.Preset(name: str, container: str, extension: str, codec: str, default_audio: str, default_subs: str)`.
  - `encode.PRESETS: dict[str, Preset]`.
  - `encode.EncodeOptions` (fields from spec; defaults `preset="mp4-h264"`, `encoder="auto"`, `quality="balanced"`, `audio_bitrate=192`, `pick="error"`).
  - `encode.EncoderChoice(family: str, video_codec: str, quality_args: tuple[str, ...])`.
  - `encode.resolve_preset(name: str) -> Preset`.
  - `encode.resolve_quality(preset: Preset, quality: str, crf: int | None) -> int`.
  - `encode.video_codec_args(choice: EncoderChoice, quality_value: int, *, ten_bit: bool) -> list[str]`.
  - `encode.encoder_candidates(preset: Preset, requested: str, ffmpeg: Path) -> list[EncoderChoice]`.
  - `encode.parse_available_encoders(ffmpeg: Path) -> set[str]`.

- [ ] **Step 1: Write the failing preset/encoder tests**

```python
# tests/test_encode_presets.py
import unittest
from pathlib import Path

from upscayl_video.encode import (
    PRESETS,
    EncoderChoice,
    encoder_candidates,
    resolve_preset,
    resolve_quality,
    video_codec_args,
)
from upscayl_video.errors import DependencyError, ValidationError


class TestPresets(unittest.TestCase):
    def test_all_presets_exist(self):
        self.assertEqual(set(PRESETS), {"mp4-h264", "mp4-hevc", "mkv-hevc", "mov-prores"})

    def test_resolve(self):
        self.assertEqual(resolve_preset("mp4-h264").extension, "mp4")
        self.assertEqual(resolve_preset("mov-prores").codec, "prores")

    def test_unknown_preset(self):
        with self.assertRaises(ValidationError):
            resolve_preset("nope")

    def test_quality_values(self):
        self.assertEqual(resolve_quality(PRESETS["mp4-h264"], "fast", None), 22)
        self.assertEqual(resolve_quality(PRESETS["mp4-h264"], "balanced", None), 20)
        self.assertEqual(resolve_quality(PRESETS["mp4-h264"], "quality", None), 18)
        self.assertEqual(resolve_quality(PRESETS["mp4-hevc"], "balanced", None), 22)
        self.assertEqual(resolve_quality(PRESETS["mp4-h264"], "balanced", 17), 17)


class TestEncoderArgs(unittest.TestCase):
    def test_nvenc_args(self):
        choice = EncoderChoice("nvidia", "h264_nvenc", ())
        args = video_codec_args(choice, 20, ten_bit=False)
        self.assertIn("h264_nvenc", args)
        self.assertIn("-cq", args)
        self.assertIn("20", args)

    def test_x264_args(self):
        choice = EncoderChoice("cpu", "libx264", ())
        args = video_codec_args(choice, 20, ten_bit=False)
        self.assertIn("libx264", args)
        self.assertIn("-crf", args)

    def test_10bit_h264_is_rejected(self):
        choice = EncoderChoice("cpu", "libx264", ())
        with self.assertRaises(ValidationError):
            video_codec_args(choice, 20, ten_bit=True)

    def test_prores_args(self):
        choice = EncoderChoice("cpu", "prores_ks", ("3",))
        args = video_codec_args(choice, 0, ten_bit=False)
        self.assertIn("prores_ks", args)
        self.assertIn("yuv422p10le", args)
```

Mock `parse_available_encoders` to test `encoder_candidates`: auto returns NVIDIA then AMD then CPU; missing forced encoder raises `DependencyError`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest tests.test_encode_presets -v`
Expected: FAIL because `encode.py` is missing.

- [ ] **Step 3: Implement presets and encoder selection**

- `PRESETS` exact values:
  - `mp4-h264`: container `mp4`, extension `mp4`, codec `h264`, default audio `auto`, default subs `auto`.
  - `mp4-hevc`: `mp4`, `mp4`, `hevc`, `auto`, `auto`.
  - `mkv-hevc`: `mkv`, `mkv`, `hevc`, `copy`, `copy`.
  - `mov-prores`: `mov`, `mov`, `prores`, `pcm`, `copy`.
- `resolve_quality`: for H.264, 22/20/18; HEVC, 24/22/20; ProRes ignore and return 0; unknown quality raises `ValidationError`; `crf` overrides in 0–51 for H.264/HEVC, 0–63 for ProRes? ProRes has no CRF; reject `crf` with ProRes.
- `parse_available_encoders`: run `ffmpeg -hide_banner -encoders`, parse lines; cache the set in a module-level dict keyed by `(ffmpeg, mtime)`; return the set.
- `encoder_candidates`: build candidates by family:
  - nvidia: `h264_nvenc` or `hevc_nvenc`.
  - amd: `h264_amf` or `hevc_amf`.
  - cpu: `libx264` or `libx265`, or `prores_ks`.
  - `auto`: nvidia, amd, cpu filtered by availability; if none, `DependencyError`.
  - forced: one candidate if available, else `DependencyError` with the missing encoder name.
- `video_codec_args`:
  - NVENC: `-c:v <codec> -preset <p5|p6|p7>` (p5 fast, p6 balanced, p7 quality), `-tune hq -rc vbr -cq <q> -b:v 0`; add `-multipass fullres -spatial_aq 1 -aq-strength 12` only for quality. The `EncoderChoice.quality_args` can carry the preset/multipass differences; `video_codec_args` can derive from `quality_args` plus the numeric value. Keep it simple: `EncoderChoice.quality_args` contains the preset/tune/rc flags except the numeric q; `video_codec_args` appends `-cq <q> -b:v 0`.
  - AMF: `-c:v <codec> -quality quality -rc cqp -qp_i <q> -qp_p <q>`.
  - x264/x265: `-c:v <codec> -preset <p> -crf <q>`.
  - ProRes: `-c:v prores_ks -profile:v <3> -vendor apl0 -pix_fmt yuv422p10le`.
  - `ten_bit`: only HEVC; use `-pix_fmt yuv420p10le`; H.264/ProRes raises `ValidationError`.
  - 8-bit default: `-pix_fmt yuv420p`.
  - AMF/NVENC `ten_bit` support: NVENC/AMF HEVC support 10-bit; pass the pix_fmt. If the encoder rejects it, the assemble fallback handles the error.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest tests.test_encode_presets -v`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/encode.py tests/test_encode_presets.py
git commit -m "feat: add output presets and encoder selection"
```

---

### Task 9: Audio and subtitle planning

**Files:**
- Modify: `src/upscayl_video/encode.py`
- Create: `tests/test_encode_audio_subs.py`

**Interfaces:**
- Consumes: `probe.MediaInfo`, `probe.StreamInfo`, `encode.Preset`.
- Produces:
  - `encode.AudioStreamPlan(source_index: int, mode: str)`.
  - `encode.AudioPlan(streams: tuple[AudioStreamPlan, ...], enabled: bool)`.
  - `encode.SubtitleStreamPlan(source_index: int, mode: str)`.
  - `encode.SubtitlePlan(streams: tuple[SubtitleStreamPlan, ...], dropped: tuple[int, ...])`.
  - `encode.plan_audio(media: MediaInfo, preset: Preset, mode: str, bitrate: int, all_audio: bool) -> AudioPlan`.
  - `encode.plan_subtitles(media: MediaInfo, preset: Preset, mode: str, logger: Logger) -> SubtitlePlan`.

- [ ] **Step 1: Write the failing audio/subtitle tests**

```python
# tests/test_encode_audio_subs.py
import unittest
from pathlib import Path

from upscayl_video.encode import PRESETS, plan_audio, plan_subtitles
from upscayl_video.errors import ValidationError
from upscayl_video.probe import StreamInfo
from upscayl_video.util import Logger
from tests.factories import make_media_info


AAC = StreamInfo(1, "aac", channels=2)
MP3 = StreamInfo(1, "mp3", channels=2)
PCM = StreamInfo(1, "pcm_s16le", channels=2)
FLAC = StreamInfo(1, "flac", channels=2)
SRT = StreamInfo(2, "subrip")
PGS = StreamInfo(2, "hdmv_pgs_subtitle")


class TestAudio(unittest.TestCase):
    def test_no_audio(self):
        media = make_media_info(Path("x.mp4"))
        plan = plan_audio(media, PRESETS["mp4-h264"], "auto", 192, False)
        self.assertFalse(plan.enabled)

    def test_aac_is_copied_in_mp4(self):
        media = make_media_info(Path("x.mp4"), audio=(AAC,))
        plan = plan_audio(media, PRESETS["mp4-h264"], "auto", 192, False)
        self.assertEqual(plan.streams[0].mode, "copy")

    def test_mp3_is_copied_in_mp4(self):
        media = make_media_info(Path("x.mp4"), audio=(MP3,))
        plan = plan_audio(media, PRESETS["mp4-h264"], "auto", 192, False)
        self.assertEqual(plan.streams[0].mode, "copy")

    def test_pcm_becomes_aac_in_mp4(self):
        media = make_media_info(Path("x.mp4"), audio=(PCM,))
        plan = plan_audio(media, PRESETS["mp4-h264"], "auto", 192, False)
        self.assertEqual(plan.streams[0].mode, "aac")

    def test_flac_is_copied_in_mkv(self):
        media = make_media_info(Path("x.mkv"), audio=(FLAC,))
        plan = plan_audio(media, PRESETS["mkv-hevc"], "auto", 192, False)
        self.assertEqual(plan.streams[0].mode, "copy")

    def test_copy_with_incompatible_codec_raises(self):
        media = make_media_info(Path("x.mp4"), audio=(PCM,))
        with self.assertRaises(ValidationError):
            plan_audio(media, PRESETS["mp4-h264"], "copy", 192, False)

    def test_all_audio_and_per_track_fallback(self):
        media = make_media_info(Path("x.mp4"), audio=(AAC, PCM))
        plan = plan_audio(media, PRESETS["mp4-h264"], "auto", 192, True)
        self.assertEqual([s.mode for s in plan.streams], ["copy", "aac"])

    def test_none_disables_audio(self):
        media = make_media_info(Path("x.mp4"), audio=(AAC,))
        plan = plan_audio(media, PRESETS["mp4-h264"], "none", 192, False)
        self.assertFalse(plan.enabled)


class TestSubtitles(unittest.TestCase):
    def test_srt_in_mp4_becomes_mov_text(self):
        media = make_media_info(Path("x.mp4"), subtitles=(SRT,))
        plan = plan_subtitles(media, PRESETS["mp4-h264"], "auto", Logger(quiet=True))
        self.assertEqual(plan.streams[0].mode, "mov_text")

    def test_srt_in_mkv_is_copied(self):
        media = make_media_info(Path("x.mkv"), subtitles=(SRT,))
        plan = plan_subtitles(media, PRESETS["mkv-hevc"], "auto", Logger(quiet=True))
        self.assertEqual(plan.streams[0].mode, "copy")

    def test_pgs_in_mp4_is_dropped(self):
        media = make_media_info(Path("x.mp4"), subtitles=(PGS,))
        plan = plan_subtitles(media, PRESETS["mp4-h264"], "auto", Logger(quiet=True))
        self.assertEqual(plan.streams, ())
        self.assertEqual(plan.dropped, (2,))

    def test_pgs_copy_in_mp4_raises(self):
        media = make_media_info(Path("x.mp4"), subtitles=(PGS,))
        with self.assertRaises(ValidationError):
            plan_subtitles(media, PRESETS["mp4-h264"], "copy", Logger(quiet=True))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest tests.test_encode_audio_subs -v`
Expected: FAIL because the planning functions are missing.

- [ ] **Step 3: Implement audio and subtitle planning**

- Container compatibility:
  - MP4: `aac`, `mp3`, `ac3`, `eac3`, `alac`.
  - MKV: any.
  - MOV: `aac`, `mp3`, `ac3`, `eac3`, `alac`, codecs starting with `pcm_`.
- `plan_audio`:
  - `mode` is one of `auto`, `copy`, `aac`, `pcm`, `none`; invalid → `ValidationError`.
  - Select first audio stream unless `all_audio`; no audio → disabled.
  - `none` → disabled.
  - `auto`: per stream copy if compatible else `aac`. For `mov-prores`, the preset default is `pcm`, so `auto` respects the preset default: if the resolved mode is `pcm`, encode all selected to `pcm_s24le` (MOV/MKV only; MP4 raises).
  - `copy`: require all selected compatible, else `ValidationError` with a hint to use `--audio aac` or `mkv-hevc`.
  - `aac`: all selected `aac`.
  - `pcm`: all selected `pcm_s24le`; MP4 raises `ValidationError`.
- `plan_subtitles`:
  - `mode` one of `auto`, `copy`, `convert`, `none`.
  - Text codecs: `subrip`, `ass`, `ssa`, `webvtt`, `mov_text`, `text`.
  - Image codecs: `hdmv_pgs_subtitle`, `dvd_subtitle`, `dvb_subtitle`, `xsub`.
  - `auto`: MKV → copy all; MP4/MOV → mov_text for text, drop image with a warning that lists the stream indices and recommends `mkv-hevc`.
  - `copy`: copy all; if any codec is image and container is MP4/MOV, raise `ValidationError`; MKV copies everything.
  - `convert`: mov_text for text; image raises `ValidationError`.
  - `none`: empty.
  - Unknown subtitle codec: treat as text for copy, but for MP4 `auto` drop it with a warning rather than risk a failed conversion. Document in code comments.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest tests.test_encode_audio_subs -v`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/encode.py tests/test_encode_audio_subs.py
git commit -m "feat: plan audio and subtitle streams"
```

---

### Task 10: Assemble command builder and output validation

**Files:**
- Modify: `src/upscayl_video/encode.py`
- Create: `tests/test_encode_command.py`

**Interfaces:**
- Consumes: `job.Job`, `frames.FrameSet`, `probe.MediaInfo`, `encode` presets/plans.
- Produces:
  - `encode.build_assemble_command(job: Job, frame_set: FrameSet, media: MediaInfo, preset: Preset, encoder: EncoderChoice, audio_plan: AudioPlan, subtitle_plan: SubtitlePlan, options: EncodeOptions, output: Path, *, frame_width: int, frame_height: int) -> list[str]`.
  - `encode.validate_output(ffprobe: Path, output: Path, job: Job, media: MediaInfo, options: EncodeOptions, expected_width: int, expected_height: int, expected_audio: bool, expected_subs: int, logger: Logger) -> None`.

- [ ] **Step 1: Write the failing command tests**

```python
# tests/test_encode_command.py
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.encode import (
    PRESETS,
    AudioPlan,
    AudioStreamPlan,
    EncodeOptions,
    EncoderChoice,
    SubtitlePlan,
    SubtitleStreamPlan,
    build_assemble_command,
    validate_output,
)
from upscayl_video.errors import OutputValidationError, ValidationError
from upscayl_video.frames import FrameSet
from upscayl_video.job import Job
from upscayl_video.probe import StreamInfo
from upscayl_video.util import Logger
from tests.factories import make_media_info


def make_job(td: str) -> Job:
    root = Path(td)
    job_dir = root / "job"
    job_dir.mkdir()
    (job_dir / "job.txt").write_text("source=x\n", encoding="utf-8")
    return Job.load(job_dir)


class TestCommand(unittest.TestCase):
    def test_mp4_h264_audio_copy_subs_mov_text(self):
        with tempfile.TemporaryDirectory() as td:
            job = make_job(td)
            media = make_media_info(Path("input.mp4"), audio=(StreamInfo(1, "aac"),), subtitles=(StreamInfo(2, "subrip"),))
            frame_set = FrameSet(Path("frames"), "png", (1,), (Path("frames/frame_00000001.png"),))
            args = build_assemble_command(
                job, frame_set, media, PRESETS["mp4-h264"],
                EncoderChoice("cpu", "libx264", ()),
                AudioPlan((AudioStreamPlan(1, "copy"),), True),
                SubtitlePlan((SubtitleStreamPlan(2, "mov_text"),), ()),
                EncodeOptions(encoder="cpu"),
                Path("out.mp4"),
                frame_width=320,
                frame_height=240,
            )
            self.assertIn("-framerate", args)
            self.assertIn("-start_number", args)
            self.assertIn("libx264", args)
            self.assertIn("mov_text", args)
            self.assertIn("+faststart", args)
            self.assertIn("-shortest", args)
            self.assertIn("1:1", args)  # absolute audio stream index
            self.assertIn("1:2", args)  # absolute subtitle stream index

    def test_no_audio_omits_shortest(self):
        with tempfile.TemporaryDirectory() as td:
            job = make_job(td)
            media = make_media_info(Path("input.mp4"))
            frame_set = FrameSet(Path("frames"), "png", (1,), (Path("frames/frame_00000001.png"),))
            args = build_assemble_command(
                job, frame_set, media, PRESETS["mp4-h264"],
                EncoderChoice("cpu", "libx264", ()),
                AudioPlan((), False), SubtitlePlan((), ()),
                EncodeOptions(encoder="cpu"), Path("out.mp4"),
                frame_width=320, frame_height=240,
            )
            self.assertIn("-an", args)
            self.assertNotIn("-shortest", args)

    def test_10bit_h264_raises(self):
        with tempfile.TemporaryDirectory() as td:
            job = make_job(td)
            media = make_media_info(Path("input.mp4"))
            frame_set = FrameSet(Path("frames"), "png", (1,), (Path("frames/frame_00000001.png"),))
            with self.assertRaises(ValidationError):
                build_assemble_command(
                    job, frame_set, media, PRESETS["mp4-h264"],
                    EncoderChoice("cpu", "libx264", ()),
                    AudioPlan((), False), SubtitlePlan((), ()),
                    EncodeOptions(encoder="cpu", ten_bit=True), Path("out.mp4"),
                    frame_width=320, frame_height=240,
                )

    def test_target_height_and_full_range(self):
        with tempfile.TemporaryDirectory() as td:
            job = make_job(td)
            media = make_media_info(Path("input.mp4"), color_range="pc")
            frame_set = FrameSet(Path("frames"), "png", (1,), (Path("frames/frame_00000001.png"),))
            args = build_assemble_command(
                job, frame_set, media, PRESETS["mp4-h264"],
                EncoderChoice("cpu", "libx264", ()),
                AudioPlan((), False), SubtitlePlan((), ()),
                EncodeOptions(encoder="cpu", target_height=1080), Path("out.mp4"),
                frame_width=3840, frame_height=2160,
            )
            vf = args[args.index("-vf") + 1]
            self.assertIn("scale=-2:1080", vf)
            self.assertIn("in_range=pc", vf)

    @patch("upscayl_video.encode.probe_media")
    def test_validate_output_wrong_width_raises(self, probe_media):
        with tempfile.TemporaryDirectory() as td:
            job = make_job(td)
            media = make_media_info(Path("input.mp4"))
            job.data["duration"] = "5.0"
            probe_media.return_value = make_media_info(Path("out.mp4"), width=100, height=240)
            with self.assertRaises(OutputValidationError):
                validate_output(
                    Path("ffprobe"), Path("out.mp4"), job, media,
                    EncodeOptions(encoder="cpu"), 320, 240, False, 0,
                    Logger(quiet=True),
                )
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest tests.test_encode_command -v`
Expected: FAIL because `build_assemble_command` is missing.

- [ ] **Step 3: Implement the command builder and validation**

- `build_assemble_command`:
  - Input: `-framerate <fps_num/fps_den> -start_number <first_index> -i <frame_set.directory>/frame_%08d.<frame_set.extension>`. The extension may be `png`, `jpg`, `jpeg`, or `webp` for manual GUI output.
  - If audio or subtitles or chapters exist, add `-i <job.source_path>` as input 1.
  - Video map `-map 0:v:0`.
  - Audio: if enabled, for each selected stream add `-map 1:<source_index>` using the **absolute** stream index from ffprobe (for example `-map 1:1`, not `-map 1:a:1`). After all maps, add per-output codec flags `-c:a:<n> copy|aac|pcm_s24le`; for `aac`, add `-b:a:<n> <bitrate>k`. If disabled, add `-an`.
  - Subtitles: for each selected stream add `-map 1:<source_index>` using the absolute stream index; add `-c:s:<n> copy|mov_text`. If none, no subtitle maps.
  - Chapters: if `media.chapters > 0`, add `-map_chapters 1`.
  - Video codec args from `video_codec_args`.
  - Optional `-vf` chain: full-range conversion + target-height downscale, in that order; use a comma-separated filter string.
  - Color tags: `-color_primaries`, `-color_trc`, `-colorspace`, `-color_range` from job/media; skip `unknown`.
  - `-metadata:s:v:0 rotate=0`, `-map_metadata 1` only when input 1 exists.
  - `-movflags +faststart` for mp4/mov.
  - `-tag:v hvc1` for HEVC + mp4/mov.
  - `-shortest` only when audio is enabled.
  - Output path.
  - Reject `ten_bit` with H.264/ProRes. Reject `target_height > frame_height`. Compute the final output dimensions (target height with proportional even width, or the frame dimensions) and reject more than 40,000,000 pixels or either dimension > 8192 unless `options.allow_huge` is set. Guard the final output, not the raw upscaled frame.
  - Use `-pix_fmt` from `video_codec_args`; do not add a second pix_fmt.
- `validate_output`:
  - Run `probe_media(ffprobe, output, logger)`.
  - Check exactly one video stream; width/height equal expected; duration within `max(0.1, 1/fps)` of `job.duration`; fps matches; audio present iff expected; subtitle count == expected; pix_fmt expected.
  - Raise `OutputValidationError` with details.
- Add `probe_first_frame_dimensions(ffprobe, path) -> tuple[int,int]` helper in `probe.py` or `encode.py`; use `ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0`. This is used by `assemble` to get frame dimensions. Add to `probe.py` in this task (modify).
- Tests for `validate_output` use a mock `probe_media` returning a `MediaInfo`; verify wrong width/duration/audio/subs raise `OutputValidationError`. Add to test file.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest tests.test_encode_command -v`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/encode.py src/upscayl_video/probe.py tests/test_encode_command.py
git commit -m "feat: build assemble commands and validate output"
```

---

### Task 11: `assemble` pipeline and CLI

**Files:**
- Modify: `src/upscayl_video/pipeline.py`
- Modify: `src/upscayl_video/cli.py`
- Create: `tests/test_pipeline_assemble.py`
- Create: `tests/integration/test_assemble.py`

**Interfaces:**
- Consumes: `encode`, `frames`, `job`, `probe`, `pipeline`.
- Produces:
  - `pipeline.run_assemble(jobs: Sequence[Job], config: Config, options: EncodeOptions, logger: Logger, *, dry_run: bool = False) -> list[Path]`.
  - `pipeline.resolve_jobs(args: Sequence[str], config: Config, *, all_jobs: bool) -> list[Job]`.
  - CLI `assemble`.

- [ ] **Step 1: Write the failing assemble tests**

```python
# tests/test_pipeline_assemble.py
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.config import load_config
from upscayl_video.encode import EncodeOptions
from upscayl_video.errors import ValidationError
from upscayl_video.job import Job
from upscayl_video.pipeline import resolve_jobs, run_assemble
from upscayl_video.util import Logger
from tests.factories import make_media_info


class TestResolveJobs(unittest.TestCase):
    def test_job_folder_and_all(self):
        with tempfile.TemporaryDirectory() as td:
            work = Path(td) / "work"
            source = Path(td) / "a.mp4"
            source.write_bytes(b"x")
            job = Job.create_or_open(work, source, Logger(quiet=True))
            job.save()
            cfg = load_config(None, overrides={"work_dir": str(work), "ffmpeg": sys.executable, "ffprobe": sys.executable})
            self.assertEqual([j.path for j in resolve_jobs([str(job.path)], cfg, all_jobs=False)], [job.path])
            self.assertEqual([j.path for j in resolve_jobs([], cfg, all_jobs=True)], [job.path])


class TestAssembleValidation(unittest.TestCase):
    def test_duplicate_frames_are_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            work = Path(td) / "work"
            source = Path(td) / "a.mp4"
            source.write_bytes(b"x")
            job = Job.create_or_open(work, source, Logger(quiet=True))
            job.update_from_media(make_media_info(source))
            job.set("frame_count", "2")
            job.save()
            job.upscaled_dir.mkdir(parents=True)
            (job.upscaled_dir / "frame_00000001.png").write_bytes(b"a")
            (job.upscaled_dir / "frame_00000001_upscayl.png").write_bytes(b"b")
            (job.upscaled_dir / "frame_00000002.png").write_bytes(b"c")
            cfg = load_config(None, overrides={"work_dir": str(work), "ffmpeg": sys.executable, "ffprobe": sys.executable})
            with patch("upscayl_video.pipeline.probe_media", return_value=make_media_info(source)):
                with self.assertRaises(ValidationError):
                    run_assemble([job], cfg, EncodeOptions(encoder="cpu"), Logger(quiet=True))
```

```python
# tests/integration/test_assemble.py
import tempfile
import unittest
from pathlib import Path

from upscayl_video.config import load_config
from upscayl_video.encode import EncodeOptions
from upscayl_video.job import Job
from upscayl_video.pipeline import run_assemble, run_split, SplitOptions
from upscayl_video.util import Logger
from tests.util import find_ffmpeg, find_ffprobe, make_clip


class TestAssembleIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = find_ffmpeg()
        if cls.ffmpeg is None:
            raise unittest.SkipTest("ffmpeg not available")
        cls.ffprobe = find_ffprobe(cls.ffmpeg)
        cls.td = tempfile.TemporaryDirectory()
        cls.root = Path(cls.td.name)
        cls.work = cls.root / "work"
        cls.clip = cls.root / "clip.mp4"
        make_clip(cls.ffmpeg, cls.clip, duration=1.0, size="160x120", fps=30)
        cls.cfg = load_config(None, overrides={"ffmpeg": cls.ffmpeg, "ffprobe": cls.ffprobe, "work_dir": str(cls.work)})
        cls.logger = Logger(quiet=True)
        cls.job = run_split(
            [cls.clip], cls.cfg,
            SplitOptions(
                fps=None, start=None, end=None, format="png", jpeg_quality=1,
                png_compression=3, denoise="none", tonemap=False, decode="cpu",
                scale=2, target_height=None, model="upscayl-standard-4x",
                verify_frames=False, recursive=False, force=False,
            ),
            cls.logger,
        )[0]

    @classmethod
    def tearDownClass(cls):
        cls.td.cleanup()

    def test_assemble_cpu_mp4_with_audio(self):
        # Simulate a manual GUI upscale by copying frames to upscaled/.
        self.job.upscaled_dir.mkdir(exist_ok=True)
        for p in sorted((self.job.frames_dir).glob("frame_*.png")):
            (self.job.upscaled_dir / p.name).write_bytes(p.read_bytes())
        outputs = run_assemble(
            [self.job], self.cfg,
            EncodeOptions(encoder="cpu", preset="mp4-h264", audio="copy", subs="auto"),
            self.logger,
        )
        self.assertTrue(outputs[0].exists())
        self.assertGreater(outputs[0].stat().st_size, 0)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest tests.test_pipeline_assemble -v`
Expected: FAIL because `run_assemble`/`resolve_jobs` are missing.

- [ ] **Step 3: Implement `run_assemble` and the CLI**

- `resolve_jobs`: accept job folders (must contain `job.txt`), or all jobs when `all_jobs=True`; refuse if neither. Sort by job id.
- `run_assemble` for each job:
  1. Load the job; point the logger at `job.logs_dir / "assemble.log"`. Check `source_changed` and require `--force` if stale.
  2. Probe the source.
  3. Choose the upscaled directory: `options.upscaled_dir` or `job.upscaled_dir`. Validate the frame set with `expected=job.get_int("frame_count") or None`, `pick=options.pick`, `verify=options.verify_frames`. If the validated count differs from `job.frame_count`, update `frame_count` and warn.
  4. If the frame set is empty, raise `ValidationError` with a hint to run Upscayl first.
  5. Build the sequence if needed (`build_sequence`); determine frame dimensions with `probe_first_frame_dimensions(ffprobe, frame_set.paths[0])`. Compute expected output dimensions: the frame dimensions, or if `target_height` is set, `height = target_height` and `width` proportional, rounded to the nearest even number.
  6. Resolve the preset; reject `ten_bit` with H.264/ProRes and `--tonemap` (not an assemble option).
  7. Resolve `audio_mode = options.audio or preset.default_audio` and `subs_mode = options.subs or preset.default_subs`; call `plan_audio`/`plan_subtitles`; create encoder candidates.
  8. Determine the output path (default `job.output_dir/<stem>_upscaled.<ext>`, collision suffix; explicit `--output` rules). With multiple jobs, `--output` must be a directory or a suffix-less path treated as a directory; a file path is a `UsageError`.
  9. For each encoder candidate (auto may have several): build the command, run it; on `CommandError`/`EncodeError`, log and try the next candidate only if `encoder=auto`; otherwise raise. For a forced encoder, fail immediately.
  10. Validate the output; on success, write `.done_assemble`, update `upscaled_count`, optionally clean.
  11. On failure, keep intermediates and `sequence/`; write `last_error`.
- CLI: add `assemble` with all options from spec section 8.5, including `--upscaled-dir`, `--pick`, `--verify-frames`, `--allow-huge`. Add `--output`, `--cleanup`, `--force`. Add `--tonemap` to the assemble parser only to reject it with a clear `ValidationError`: tonemapping is a split-stage option.
- Tests for CLI: `assemble --help`; a job folder with frames exits 0; explicit output collision exits 4.

- [ ] **Step 4: Run the tests to verify they pass**

Run:
- `python -m unittest tests.test_pipeline_assemble -v`
- `python -m unittest tests.integration.test_assemble -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/pipeline.py src/upscayl_video/cli.py tests/test_pipeline_assemble.py tests/integration/test_assemble.py
git commit -m "feat: assemble upscaled frames into video"
```

---

### Task 12: `status` and `clean`

**Files:**
- Modify: `src/upscayl_video/pipeline.py`
- Modify: `src/upscayl_video/cli.py`
- Create: `tests/test_status_clean.py`

**Interfaces:**
- Consumes: `job.find_jobs`, `frames.count_contiguous_frames`, `util.ensure_within`.
- Produces:
  - `pipeline.run_status(config: Config, logger: Logger, *, verbose: bool = False) -> None`.
  - `pipeline.run_clean(jobs: Sequence[Job], config: Config, *, frames: bool, upscaled: bool, chunks: bool, sequence: bool, batch: bool, include_output: bool, all_intermediates: bool, dry_run: bool, logger: Logger) -> None`.
  - CLI `status`, `clean`.

- [ ] **Step 1: Write the failing status/clean tests**

```python
# tests/test_status_clean.py
import sys
import tempfile
import unittest
from pathlib import Path

from upscayl_video.config import load_config
from upscayl_video.errors import ValidationError
from upscayl_video.job import Job
from upscayl_video.pipeline import run_clean
from upscayl_video.util import Logger


class TestClean(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.root = Path(self.td.name)
        self.work = self.root / "work"
        self.source = self.root / "clip.mp4"
        self.source.write_bytes(b"source")
        self.job = Job.create_or_open(self.work, self.source, Logger(quiet=True))
        self.job.set("frame_count", "1")
        self.job.save()
        for name in ("frames", "upscaled", "chunks", "sequence", "output"):
            (self.job.path / name).mkdir()
            (self.job.path / name / "x").write_bytes(b"x")

    def tearDown(self):
        self.td.cleanup()

    def test_all_intermediates_keeps_source_and_output(self):
        run_clean(
            [self.job], load_config(None, overrides={"work_dir": str(self.work), "ffmpeg": sys.executable, "ffprobe": sys.executable}),
            frames=False, upscaled=False, chunks=False, sequence=False, batch=False,
            include_output=False, all_intermediates=True, dry_run=False,
            logger=Logger(quiet=True),
        )
        self.assertFalse((self.job.path / "frames").exists())
        self.assertFalse((self.job.path / "upscaled").exists())
        self.assertTrue((self.job.path / "output").exists())
        self.assertTrue(self.source.exists())

    def test_include_output(self):
        run_clean(
            [self.job], load_config(None, overrides={"work_dir": str(self.work), "ffmpeg": sys.executable, "ffprobe": sys.executable}),
            frames=False, upscaled=False, chunks=False, sequence=False, batch=False,
            include_output=True, all_intermediates=False, dry_run=False,
            logger=Logger(quiet=True),
        )
        self.assertFalse((self.job.path / "output").exists())

    def test_refuses_job_outside_work_dir(self):
        other_work = self.root / "other"
        other_job = Job.create_or_open(other_work, self.source, Logger(quiet=True))
        other_job.save()
        with self.assertRaises(ValidationError):
            run_clean(
                [other_job],
                load_config(None, overrides={"work_dir": str(self.work), "ffmpeg": sys.executable, "ffprobe": sys.executable}),
                frames=True, upscaled=False, chunks=False, sequence=False, batch=False,
                include_output=False, all_intermediates=False, dry_run=True,
                logger=Logger(quiet=True),
            )
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest tests.test_status_clean -v`
Expected: FAIL because `run_clean`/`run_status` are missing.

- [ ] **Step 3: Implement status and clean**

- `run_status`: scan `config.work_dir` with `find_jobs`; print a table with job id, stage, frames, upscaled, output. Stage: `done` if `.done_assemble`, `assemble` if upscaled frames exist, `upscale` if frames exist, `split` if `.done_split`, `failed` if `last_error`, `empty` otherwise. For each job, count frames in `frames/` and `upscaled/`; if `frame_count` is set and chunk markers exist (not in this plan), use the metadata. `--verbose` prints full paths and job settings.
- `run_clean`: for each job, verify `job.path` is inside `config.work_dir` and contains `job.txt`; select targets:
  - `all_intermediates` = frames, upscaled, chunks, sequence, batch_*.
  - explicit flags add targets.
  - `include_output` adds `output/`.
  - `dry_run` prints what would be deleted.
  - Delete directories with `shutil.rmtree`; delete `batch_*` dirs via glob; never delete `job.txt`, `source.txt`, logs, markers, or the source.
- CLI: add `status` and `clean` commands. `clean` options `--frames`, `--upscaled`, `--chunks`, `--batch`, `--all-intermediates`, `--include-output`, `--all-jobs`, `--dry-run`. `status` options `--verbose`.
- Tests for `run_status` capture stdout and assert the job row; `clean` with `--dry-run` leaves files.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest tests.test_status_clean -v`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/pipeline.py src/upscayl_video/cli.py tests/test_status_clean.py
git commit -m "feat: add status and clean commands"
```

---

### Task 13: `doctor`

**Files:**
- Create: `src/upscayl_video/doctor.py`
- Modify: `src/upscayl_video/cli.py`
- Create: `tests/test_doctor.py`

**Interfaces:**
- Consumes: `config.Config`, `util.run_command`, `disk.free_bytes`.
- Produces:
  - `doctor.CheckResult(name: str, status: str, detail: str)`.
  - `doctor.run_doctor(config: Config, *, work_dir: Path | None, skip_upscayl_smoke: bool, verbose: bool, logger: Logger) -> int`.
  - `doctor.check_ffmpeg(config, logger) -> list[CheckResult]`.
  - `doctor.check_encoders(config, logger) -> list[CheckResult]`.
  - `doctor.check_work_dir(config, work_dir, logger) -> list[CheckResult]`.

- [ ] **Step 1: Write the failing doctor tests**

```python
# tests/test_doctor.py
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.config import load_config
from upscayl_video.doctor import CheckResult, check_encoders, check_ffmpeg, run_doctor
from upscayl_video.util import Logger


class TestDoctor(unittest.TestCase):
    def test_non_ffmpeg_executable_fails(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = load_config(None, overrides={"ffmpeg": sys.executable, "ffprobe": sys.executable, "work_dir": td})
            results = check_ffmpeg(cfg, Logger(quiet=True))
            self.assertTrue(any(r.status == "FAIL" for r in results))

    def test_encoder_parse(self):
        with patch("upscayl_video.doctor.run_command") as run:
            run.return_value.stdout = " V....D libx264 H.264\n V....D libx265 HEVC\n"
            run.return_value.returncode = 0
            results = check_encoders(
                load_config(None, overrides={"ffmpeg": sys.executable, "ffprobe": sys.executable}),
                Logger(quiet=True),
            )
            self.assertTrue(any(r.name == "libx264" and r.status == "OK" for r in results))

    def test_low_disk_exit_code(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = load_config(None, overrides={"ffmpeg": sys.executable, "ffprobe": sys.executable, "work_dir": td})
            ok = [CheckResult("ffmpeg", "OK", "test")]
            with patch("upscayl_video.doctor.check_ffmpeg", return_value=ok), \
                 patch("upscayl_video.doctor.check_encoders", return_value=ok), \
                 patch("upscayl_video.doctor.free_bytes", return_value=0):
                code = run_doctor(cfg, work_dir=Path(td), skip_upscayl_smoke=True, verbose=False, logger=Logger(quiet=True))
            self.assertEqual(code, 5)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest tests.test_doctor -v`
Expected: FAIL because `doctor.py` is missing.

- [ ] **Step 3: Implement `doctor.py` and CLI**

- `check_ffmpeg`: run `ffmpeg -version` and `ffprobe -version`; if nonzero, return FAIL with the stderr tail. Verify the first line contains `ffmpeg version` / `ffprobe version`; otherwise FAIL, so a random executable cannot pass. Parse the version. Also run `ffmpeg -hide_banner -filters` and report whether `zscale` is present (WARN if missing; only needed for tonemap). Report glob support as INFO/WARN; not required.
- `check_encoders`: run `ffmpeg -hide_banner -encoders`; check `libx264` (required), `libx265`, `prores_ks`, `h264_nvenc`, `hevc_nvenc`, `h264_amf`, `hevc_amf`. Required missing → FAIL; preset-specific/optional missing → WARN.
- `check_work_dir`: create the work dir if missing; write a temp file and delete it; check free space against `min_free_gb`; return FAIL if below.
- `run_doctor`: collect results, print a table `STATUS  NAME  DETAIL`; print a summary. Exit 3 if any required FFmpeg/ffprobe or libx264 check fails; 5 if disk fails; otherwise 0. Upscayl is not checked in this plan; print an INFO line: "Upscayl checks are added with the automated upscale stage." This is honest and avoids claiming a check that does not exist.
- CLI `doctor` options `--work-dir`, `--skip-upscayl-smoke`, `--verbose`; `--skip-upscayl-smoke` is accepted for forward compatibility but is a no-op in this plan.
- Tests: missing ffmpeg returns 3; low disk returns 5; encoder parsing; output table.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest tests.test_doctor -v`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/doctor.py src/upscayl_video/cli.py tests/test_doctor.py
git commit -m "feat: add doctor environment checks"
```

---

### Task 14: Basic menu and launchers

**Files:**
- Create: `src/upscayl_video/menu.py`
- Create: `upscayl-video.bat`
- Create: `upscayl-video.sh`
- Modify: `src/upscayl_video/cli.py`
- Create: `tests/test_menu.py`
- Create: `tests/test_launchers.py`

**Interfaces:**
- Consumes: `cli.main` dispatch functions or `pipeline` directly.
- Produces:
  - `menu.run_menu(config: Config | None, logger: Logger) -> int`.
  - Launchers that forward argv to the Python launcher.

- [ ] **Step 1: Write the failing menu/launcher tests**

```python
# tests/test_menu.py
import unittest
from unittest.mock import patch

from upscayl_video.menu import run_menu
from upscayl_video.util import Logger


class TestMenu(unittest.TestCase):
    def test_exit_choice(self):
        with patch("builtins.input", side_effect=["9"]):
            self.assertEqual(run_menu(None, Logger(quiet=True)), 0)

    def test_invalid_then_exit(self):
        with patch("builtins.input", side_effect=["99", "9"]):
            self.assertEqual(run_menu(None, Logger(quiet=True)), 0)
```

```python
# tests/test_launchers.py
import subprocess
import sys
import unittest
from pathlib import Path


class TestLaunchers(unittest.TestCase):
    def test_python_launcher_version(self):
        root = Path(__file__).resolve().parents[1]
        result = subprocess.run(
            [sys.executable, str(root / "upscayl-video.py"), "--version"],
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0.1.0", result.stdout)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest tests.test_menu -v`
Expected: FAIL because `menu.py` is missing or `run_menu` does not accept `None`.

- [ ] **Step 3: Implement the menu and launchers**

- `run_menu`: accept `config: Config | None` for testability. Print:
  ```
  Upscayl Video Pipeline
  1) Split video(s)
  2) Assemble a job
  3) Status
  4) Doctor
  5) Clean a job
  6) Exit
  ```
  Loop until exit. Prompt with defaults. For split, ask for a file/folder, frame format (png/jpg), scale (2/3/4), and then call `run_split` with defaults from config. For assemble, ask for a job folder, preset, encoder, audio, subs, and call `run_assemble`. For status/doctor/clean, call the corresponding functions. Catch `PipelineError`, print `message` and `hint`, and continue. Ctrl+C exits 130. If `config is None` in tests, only the exit/invalid choices are exercised; for real menu use, `cli.main` loads the config before calling.
- `upscayl-video.bat`:
  ```bat
  @echo off
  chcp 65001 >nul
  setlocal
  where py >nul 2>nul
  if %ERRORLEVEL%==0 (
      py -3 "%~dp0upscayl-video.py" %*
  ) else (
      python "%~dp0upscayl-video.py" %*
  )
  exit /b
  ```
  Keep the launcher simple; the README documents Python 3.10+.
- `upscayl-video.sh`:
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  exec python3 "$SCRIPT_DIR/upscayl-video.py" "$@"
  ```
  Set executable bit: `git update-index --chmod=+x upscayl-video.sh` or `chmod +x` on Unix.
- CLI: if no args and stdin is a TTY, load config and call `run_menu`; if no args and no TTY, print help and return 2.
- Tests: launcher `--version`; menu exit; menu invalid choice. Do not test the `.bat`/`.sh` on the wrong OS.

- [ ] **Step 4: Run the tests to verify they pass**

Run:
- `python -m unittest tests.test_menu -v`
- `python -m unittest tests.test_launchers -v`
- `./upscayl-video.sh --version` (Git Bash/Linux/macOS) or `upscayl-video.bat --version` (Windows)

Expected: all PASS; version prints `0.1.0`.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/menu.py src/upscayl_video/cli.py upscayl-video.bat upscayl-video.sh tests/test_menu.py tests/test_launchers.py
git commit -m "feat: add basic menu and launchers"
```

---

### Task 15: Manual GUI workflow integration and core docs

**Files:**
- Create: `tests/integration/test_manual_workflow.py`
- Create: `tests/fixtures/make_fixtures.py`
- Create: `docs/USAGE.md`
- Create: `docs/TROUBLESHOOTING.md`
- Modify: `README.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: the complete core CLI.
- Produces: a reproducible end-to-end manual workflow and user documentation.

- [ ] **Step 1: Write the failing end-to-end test**

```python
# tests/integration/test_manual_workflow.py
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tests.util import find_ffmpeg, find_ffprobe, make_clip, ffprobe_json


class TestManualWorkflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = find_ffmpeg()
        if cls.ffmpeg is None:
            raise unittest.SkipTest("ffmpeg not available")
        cls.ffprobe = find_ffprobe(cls.ffmpeg)
        cls.td = tempfile.TemporaryDirectory()
        cls.root = Path(cls.td.name)
        cls.clip = cls.root / "test diakritika žluťoučký.mp4"
        make_clip(cls.ffmpeg, cls.clip, duration=2.0, size="160x120", fps=30)
        cls.work = cls.root / "work"

    @classmethod
    def tearDownClass(cls):
        cls.td.cleanup()

    def test_split_rename_and_assemble(self):
        root = Path(__file__).resolve().parents[2]
        launcher = root / "upscayl-video.py"
        split = subprocess.run(
            [sys.executable, str(launcher), "split", str(self.clip),
             "--work-dir", str(self.work), "--format", "png", "--decode", "cpu",
             "--ffmpeg", self.ffmpeg, "--ffprobe", self.ffprobe],
            text=True, capture_output=True,
        )
        self.assertEqual(split.returncode, 0, split.stderr)
        job_dir = self.work / "test_diakritika_žluťoučký"
        self.assertTrue(job_dir.exists(), list(self.work.iterdir()))
        frames = sorted((job_dir / "frames").glob("frame_*.png"))
        self.assertEqual(len(frames), 60)
        upscaled = job_dir / "upscaled"
        upscaled.mkdir()
        for frame in frames:
            # Simulate Upscayl's suffixed output names.
            (upscaled / f"{frame.stem}_upscayl_4x_upscayl-standard-4x.png").write_bytes(frame.read_bytes())
        assemble = subprocess.run(
            [sys.executable, str(launcher), "assemble", str(job_dir),
             "--preset", "mp4-h264", "--encoder", "cpu", "--audio", "copy", "--subs", "auto",
             "--ffmpeg", self.ffmpeg, "--ffprobe", self.ffprobe],
            text=True, capture_output=True,
        )
        self.assertEqual(assemble.returncode, 0, assemble.stderr)
        output = job_dir / "output" / "test diakritika žluťoučký_upscaled.mp4"
        self.assertTrue(output.exists())
        info = ffprobe_json(self.ffprobe, output)
        video = [s for s in info["streams"] if s["codec_type"] == "video"][0]
        self.assertEqual((video["width"], video["height"]), (160, 120))
        self.assertAlmostEqual(float(info["format"]["duration"]), 2.0, delta=0.15)
        self.assertTrue(any(s["codec_type"] == "audio" for s in info["streams"]))
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python -m unittest tests.integration.test_manual_workflow -v`
Expected: FAIL until the CLI supports the full path and the job id sanitization matches the expected `test_diakritika_žluťoučký`.

- [ ] **Step 3: Fix integration issues and write the docs**

- If the job id includes a trailing `_` or different sanitization, fix `sanitize_job_id` and the test expectation. The spec says keep Unicode, replace whitespace with `_`, strip `._ `.
- Ensure `split` on a path with spaces/Unicode quotes every argument correctly (Python list args, no shell).
- Ensure the assemble output name preserves the source stem with spaces/Unicode.
- `tests/fixtures/make_fixtures.py <out-dir>` generates the core fixture matrix with FFmpeg: `clip.mp4` (5 s, 320×240, 30 fps, H.264 + AAC), `clip_noaudio.mp4`, `clip_subs.mkv` (H.264 + MP3 + SRT + a chapter), `clip_odd.mkv` (321×241 FFV1), `clip_10bit.mkv` (HEVC 10-bit SDR), and `clip_long.mp4` (20 s). It prints the generated paths and is used for manual QA.
- Write `docs/USAGE.md`: `doctor`, `split`, `assemble`, `status`, `clean`, manual GUI walkthrough, all flags, exit codes, `job.txt`/`config.txt`.
- Write `docs/TROUBLESHOOTING.md`: FFmpeg not found, Unicode/space paths, audio copy failures, image subtitles in MP4, HDR rejection, low disk, output validation failures.
- Update `README.md`: status "V1 core implemented; automated upscale, run, chunking, and V2 are next", quick start, manual GUI workflow, requirements.
- Update `CHANGELOG.md` with the core features.

- [ ] **Step 4: Run the test and full suite to verify they pass**

Run:
- `python -m unittest tests.integration.test_manual_workflow -v`
- `python -m unittest discover -s tests -v`

Expected: all tests PASS; the integration test creates and removes its temp files.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/test_manual_workflow.py tests/fixtures/make_fixtures.py docs/USAGE.md docs/TROUBLESHOOTING.md README.md CHANGELOG.md
git commit -m "test: cover manual upscale workflow and document core"
```

---

### Task 16: Final core QA and handoff

**Files:**
- Modify: `CHANGELOG.md` if needed.
- No new code unless QA finds a bug.

**Interfaces:**
- Consumes: the complete core.
- Produces: a clean, tested V1 core ready for the automation plan.

- [ ] **Step 1: Run the full test suite**

Run: `python -m unittest discover -s tests -v`
Expected: all tests PASS, with integration tests either passing or skipping only when FFmpeg is unavailable.

- [ ] **Step 2: Run the doctor and a manual real-clip check**

Run (adjust the FFmpeg path to the machine):

```bash
python upscayl-video.py doctor --ffmpeg "C:\FFMPEG\ffmpeg.exe" --ffprobe "C:\FFMPEG\ffprobe.exe"
python upscayl-video.py split "C:\path\to\clip.mp4" --work-dir "D:\UpscaylVideo" --decode cpu
# In Upscayl: input work\clip\frames, output work\clip\upscaled, batch upscale
python upscayl-video.py assemble "D:\UpscaylVideo\clip" --preset mp4-h264 --encoder auto --audio auto --subs auto
```

Expected: `doctor` exits 0 (warnings are allowed); split creates frames; assemble creates a playable MP4 with audio. Play the output and verify duration/audio start.

- [ ] **Step 3: Check the working tree and commit any QA fixes**

Run: `git status --short`
Expected: clean. If QA required a fix, commit it with a focused message.

- [ ] **Step 4: Update the changelog and README status**

Mark V1 core as implemented. Do not tag a release; the full V1 plan will tag `v0.1.0`.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md README.md
git commit -m "docs: mark V1 core complete"
```

---

## Self-Review

### Spec coverage for this plan

| Spec area | Task |
|---|---|
| Python package, errors, logging, paths | 1 |
| `config.txt`, ffmpeg/ffprobe discovery | 2 |
| `job.txt`, `source.txt`, markers, job reuse | 3 |
| ffprobe metadata, fps, streams, HDR, rotation | 4 |
| Frame extraction, CFR, resume, denoise, tonemap, PNG/JPEG, sequence normalization | 5 |
| Disk estimate and free-space check | 6 |
| `split` command and input resolution | 7 |
| Presets, quality mapping, NVENC/AMF/CPU selection | 8 |
| Audio/subtitle planning and compatibility | 9 |
| Assemble command, color/rotation/target height, output validation | 10 |
| `assemble` command, encoder fallback, output collision | 11 |
| `status`, `clean` | 12 |
| `doctor` (FFmpeg/encoders/work dir; Upscayl deferred with a clear note) | 13 |
| Basic menu, launchers | 14 |
| Manual GUI workflow, docs | 15 |
| Final QA | 16 |

Explicitly out of scope for this plan: automated `upscale`, `run`, chunking, ETA, full menu, Upscayl discovery/ICD/batching, V2 Windows/Unix. These are plan 2 and plans 3–4. The spec's chunking/upscale sections are not implemented here; the code must not pretend they are.

### Type consistency

- `MediaInfo` fields are defined in Task 3 and used unchanged in Tasks 4–11.
- `FrameSet` fields are defined in Task 5 and used unchanged in Tasks 10–11.
- `EncodeOptions` fields are defined in Task 8 and used unchanged in Tasks 10–11.
- `Job.get_int`/`get_bool` are used for `frame_count`, `chapters`, etc.
- `run_split` returns `list[Job]`; `run_assemble` takes `Sequence[Job]` and returns `list[Path]`.
- `resolve_jobs` and `resolve_inputs` return `list[Path]`/`list[Job]` consistently.

### Review Focus tests

- Paths with spaces/Unicode: Tasks 1 (`sanitize_job_id`), 3 (`source` round-trip), 7 (`resolve_inputs`), 11 (assemble), 15 (end-to-end).
- Odd dimensions/rotation/anamorphic: Tasks 4 (rotation parsing), 5 (pad filter), 7 (odd source), 10 (rotation strip). Anamorphic is documented as a limitation; no special correction.
- Audio mismatch/no audio/multiple tracks: Task 9 unit tests and Task 11 integration.
- Subtitle mismatch: Task 9 unit tests and Task 11 integration; image-subtitle integration can use a mocked plan if generating PGS is impractical.
- Partial frames/HDR/10-bit/VFR: Task 5 resume, Task 7 HDR rejection, Task 4 10-bit detection, Task 5 CFR command. VFR integration is optional; the command uses `-fps_mode cfr`.

### Known deferred items

- Upscayl CLI/model discovery, ICD workaround, tile/batch sizing, memory-leak batching: plan 2.
- `run`, chunking, ETA, full menu: plan 2.
- V2 PowerShell/bash parity: plans 3–4.
- Real 1080p/4K performance validation: final QA in plan 2/7.
