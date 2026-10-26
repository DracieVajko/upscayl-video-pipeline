# Upscayl Video Pipeline — V1 Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add automated `upscayl-bin` upscaling, an all-in-one `run` command, time-based chunking for long videos, ETA/progress warnings, and a complete `doctor`/menu to the existing V1 core.

**Architecture:** A new `upscayl.py` owns CLI/model/ICD discovery, VRAM/tile selection, smoke tests, and memory-leak-safe frame batching. A new `progress.py` owns counters/ETA. A new `chunking.py` plans exact frame ranges and builds video-only segment/concat commands. `pipeline.py` adds `run_upscale` and `run_all`; `cli.py` adds `upscale` and `run`; `doctor.py` and `menu.py` gain the full automation paths. The existing `job.txt` contract is extended, not replaced.

**Tech Stack:** Python 3.10+ (stdlib only), FFmpeg/ffprobe, `upscayl-bin` 2.15.x, `unittest`, PowerShell/bash launchers. No third-party Python packages, no network access.

**Spec:** `docs/specs/2026-10-26-upscayl-video-pipeline-design.md`

This is plan 2 of 4. Plan 1 (V1 core: split, manual Upscayl GUI, assemble) is merged on `main` at `3ddcbce`. Plans 3–4 implement V2 Windows/Unix. This plan produces a complete automated V1 and does not touch V2.

---

## Global Constraints

- Python 3.10+ only; standard library only; no `pip install`, no network calls.
- Keep the existing V1 core behavior and tests green. `split`, `assemble`, `status`, `clean`, and the manual GUI workflow must continue to work without Upscayl.
- Upscayl is required for `upscale` and `run`; `split`/`assemble` remain usable without it.
- Never delete or overwrite the source video. Never delete outside the job folder without explicit consent.
- Encode through a temporary `*.partial.<ext>` file and `os.replace` only after validation.
- `job.txt` remains UTF-8 key=value, atomic, unknown keys preserved.
- The UI and docs are English.
- All new FFmpeg/Upscayl child processes use argument lists, absolute paths where needed, and `-nostdin`.
- Default model `upscayl-standard-4x`; default scale `2`; default batch size `100`; default tile from VRAM; default chunk length `60` seconds when chunking is enabled.
- Upscayl output is always PNG (`-f png -c 0`) for a lossless intermediate.
- No parallel jobs on one GPU. Jobs run sequentially.
- Every task ends with the full test suite green and a commit.
- Do not claim success without reading the test output.

---

## Review Focus

These are the failure modes most likely to bite a real user in this plan. Each gets tests in the owning task.

1. **Windows/AMD Vulkan enumeration** — `vkEnumeratePhysicalDevices failed 5` must be diagnosed and bypassed with the NVIDIA ICD, without modifying system drivers. Tests: Tasks 1, 2, 12.
2. **Upscayl batch memory leak/partial output** — restart the process per batch, resume missing frames, never move a zero-byte or half-written output. Tests: Tasks 3, 4, 13.
3. **VRAM/tile/OOM** — 4 GiB cards need smaller tiles; auto tile was ~10× slower; a failed batch must retry with halved tile/batch. Tests: Tasks 1, 3, 4.
4. **Chunk boundaries and A/V sync** — cumulative frame rounding, video-only segments, concat, then mux audio/subs with `-t`; no lost/duplicated frames at boundaries. Tests: Tasks 8, 9, 13.
5. **Long-video disk/ETA** — disk estimate, chunking decision, cleanup, and a warning before multi-hour runs. Tests: Tasks 7, 9, 10.
6. **CLI/menu/doctor error paths** — missing Upscayl, missing models, forced encoder failure, chunked-job misuse, and Ctrl+C leave resumable state. Tests: Tasks 2, 5, 6, 11, 13.

---

## File Map

| Path | Responsibility |
|---|---|
| `src/upscayl_video/upscayl.py` | Discovery, models, ICD, VRAM/tile, smoke test, batch upscaling |
| `src/upscayl_video/progress.py` | Counters, rate, ETA, periodic progress lines |
| `src/upscayl_video/chunking.py` | Chunk plan, exact frame ranges, segment encode, concat list |
| `src/upscayl_video/pipeline.py` | Add `run_upscale`, `run_all`, chunk orchestration, cleanup |
| `src/upscayl_video/cli.py` | Add `upscale`, `run`; extend menu/doctor dispatch |
| `src/upscayl_video/doctor.py` | Upscayl discovery/models/smoke; encoder smoke tests |
| `src/upscayl_video/menu.py` | Full 9-option menu |
| `src/upscayl_video/job.py` | Chunk markers, model/scale validation helpers |
| `src/upscayl_video/encode.py` | Video-only segment command, `-t` mux helpers |
| `tests/test_upscayl_discovery.py` | Discovery, models, ICD, tile, batch sizing |
| `tests/test_upscayl_batch.py` | Batch/resume/retry with a fake upscaler |
| `tests/test_upscale_pipeline.py` | `upscale` job flow and CLI |
| `tests/test_run_pipeline.py` | All-in-one multi-video flow |
| `tests/test_chunking.py` | Chunk math, segment encode, concat/mux |
| `tests/test_progress.py` | ETA math and formatting |
| `tests/test_doctor_upscayl.py` | Doctor Upscayl checks |
| `tests/fixtures/fake_upscayl.py` | Cross-platform fake `upscayl-bin` |
| `tests/integration/test_upscale_real.py` | Real Upscayl smoke test, skipped if unavailable |
| `tests/integration/test_run_chunked.py` | End-to-end chunked run with fake upscaler |
| `docs/USAGE.md`, `docs/TROUBLESHOOTING.md`, `README.md`, `CHANGELOG.md` | Automation docs |

---

### Task 1: Upscayl discovery, models, ICD, VRAM, tile

**Files:**
- Create: `src/upscayl_video/upscayl.py`
- Create: `tests/test_upscayl_discovery.py`

**Interfaces:**
- Consumes: `config.Config`, `errors.DependencyError`, `errors.ValidationError`, `util.run_command`.
- Produces:
  - `upscayl.ModelInfo(name: str, param: Path, weights: Path)`.
  - `upscayl.UpscaylPaths(binary: Path, models_dir: Path)`.
  - `upscayl.discover_upscayl(config: Config) -> UpscaylPaths`.
  - `upscayl.list_models(models_dir: Path) -> list[ModelInfo]`.
  - `upscayl.find_nvidia_icd() -> Path | None`.
  - `upscayl.resolve_icd(config: Config, override: str | None = None) -> Path | None`.
  - `upscayl.detect_vram_mb() -> int | None`.
  - `upscayl.resolve_tile(requested: str, vram_mb: int | None) -> int`.
  - `upscayl.resolve_batch_size(requested: int, frame_width: int, frame_height: int) -> int`.

- [ ] **Step 1: Write the failing discovery tests**

```python
# tests/test_upscayl_discovery.py
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.config import load_config
from upscayl_video.errors import DependencyError, ValidationError
from upscayl_video.upscayl import (
    ModelInfo,
    UpscaylPaths,
    discover_upscayl,
    find_nvidia_icd,
    list_models,
    resolve_batch_size,
    resolve_tile,
)


class TestModels(unittest.TestCase):
    def test_lists_complete_pairs_only(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "a.param").write_text("x", encoding="utf-8")
            (root / "a.bin").write_bytes(b"x")
            (root / "b.param").write_text("x", encoding="utf-8")
            models = list_models(root)
            self.assertEqual([model.name for model in models], ["a"])

    def test_missing_models_dir_raises(self):
        with self.assertRaises(DependencyError):
            list_models(Path("does-not-exist"))


class TestTile(unittest.TestCase):
    def test_auto_by_vram(self):
        self.assertEqual(resolve_tile("auto", 4096), 128)
        self.assertEqual(resolve_tile("auto", 6144), 256)
        self.assertEqual(resolve_tile("auto", 12288), 512)
        self.assertEqual(resolve_tile("auto", None), 256)

    def test_explicit_tile(self):
        self.assertEqual(resolve_tile("128", 6144), 128)

    def test_tile_below_32_is_rejected(self):
        with self.assertRaises(ValidationError):
            resolve_tile("16", 6144)


class TestBatch(unittest.TestCase):
    def test_large_frames_use_smaller_batch(self):
        self.assertEqual(resolve_batch_size(0, 1920, 1080), 100)
        self.assertEqual(resolve_batch_size(0, 3840, 2160), 50)

    def test_explicit_batch_wins(self):
        self.assertEqual(resolve_batch_size(7, 3840, 2160), 7)


class TestDiscovery(unittest.TestCase):
    def test_config_binary_and_models(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            binary = root / ("upscayl-bin.exe" if __import__("os").name == "nt" else "upscayl-bin")
            binary.write_bytes(b"")
            models = root / "models"
            models.mkdir()
            (models / "m.param").write_text("x", encoding="utf-8")
            (models / "m.bin").write_bytes(b"x")
            cfg = load_config(None, overrides={
                "ffmpeg": __import__("sys").executable,
                "ffprobe": __import__("sys").executable,
                "upscayl_bin": str(binary),
                "models_dir": str(models),
            })
            paths = discover_upscayl(cfg)
            self.assertEqual(paths.binary, binary.resolve())
            self.assertEqual(paths.models_dir, models.resolve())

    def test_missing_binary_raises(self):
        cfg = load_config(None, overrides={
            "ffmpeg": __import__("sys").executable,
            "ffprobe": __import__("sys").executable,
            "upscayl_bin": "/missing/upscayl-bin",
        })
        with self.assertRaises(DependencyError):
            discover_upscayl(cfg)


class TestIcd(unittest.TestCase):
    @patch("upscayl_video.upscayl._find_nvidia_icd_windows", return_value=Path("C:/nv-vk64.json"))
    def test_auto_returns_nvidia_icd(self, _find):
        cfg = load_config(None, overrides={
            "ffmpeg": __import__("sys").executable,
            "ffprobe": __import__("sys").executable,
        })
        self.assertEqual(find_nvidia_icd(), Path("C:/nv-vk64.json"))

    @patch("upscayl_video.upscayl._find_nvidia_icd_windows", return_value=None)
    def test_auto_without_nvidia_returns_none(self, _find):
        self.assertIsNone(find_nvidia_icd())
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest tests.test_upscayl_discovery -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'upscayl_video.upscayl'`.

- [ ] **Step 3: Implement `upscayl.py` discovery and sizing**

- `discover_upscayl`: precedence `--upscayl-bin` (passed via config overrides), `config.upscayl_bin`, `UPSCAYL_BIN`, Windows install paths, `PATH`, Linux `/opt/upscayl`, macOS app bundle. Resolve the binary; require a file.
- Models: `--models-dir`/config/`UPSCAYL_MODELS`, `../models` relative to the binary, standard install paths. Require a directory with at least one complete `.param` + `.bin` pair. Return sorted models.
- `find_nvidia_icd`: Windows only; glob `C:\Windows\System32\DriverStore\FileRepository\nv*\nv-vk64.json`, return the first readable path. Linux/macOS: return `None` unless a known path exists. Cache the result in a module-level variable.
- `resolve_icd`: `override`/`config.icd`; `none` → `None`; `auto` → NVIDIA ICD when present; explicit path must exist. Do not set environment globally.
- `detect_vram_mb`: `nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits`; fallback WMI `AdapterRAM`; return MiB or `None`.
- `resolve_tile`: `auto` table 4096→128, 8192→256, else 512, unknown 256; explicit integer ≥32; reject <32.
- `resolve_batch_size`: explicit >0 wins; default 100; if `width*height > 8_000_000`, 50.
- All child commands use `run_command` with a `Logger`; no network.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m unittest tests.test_upscayl_discovery -v`
Expected: all tests PASS. Add a real-machine smoke test in Task 2; this task uses mocks/fake files.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/upscayl.py tests/test_upscayl_discovery.py
git commit -m "feat: discover Upscayl and size GPU batches"
```

---

### Task 2: Upscayl smoke test and doctor integration

**Files:**
- Modify: `src/upscayl_video/upscayl.py`
- Modify: `src/upscayl_video/doctor.py`
- Modify: `src/upscayl_video/cli.py`
- Create: `tests/test_doctor_upscayl.py`
- Create: `tests/integration/test_upscale_real.py`

**Interfaces:**
- Consumes: `upscayl.discover_upscayl`, `upscayl.list_models`, `upscayl.resolve_icd`, `upscayl.resolve_tile`, `util.run_command`.
- Produces:
  - `upscayl.smoke_test(paths: UpscaylPaths, model: str, tile: int, icd: Path | None, logger: Logger) -> tuple[bool, str]`.
  - `doctor.check_upscayl(config: Config, *, skip_smoke: bool, logger: Logger) -> list[CheckResult]`.
  - Real integration test `tests/integration/test_upscale_real.py` skipped when Upscayl/GPU is unavailable.

- [ ] **Step 1: Write the failing smoke/doctor tests**

```python
# tests/test_doctor_upscayl.py
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.config import load_config
from upscayl_video.doctor import CheckResult, check_upscayl, run_doctor
from upscayl_video.errors import CommandError, DependencyError
from upscayl_video.util import Logger
from upscayl_video.upscayl import UpscaylPaths, smoke_test


class TestSmoke(unittest.TestCase):
    @patch("upscayl_video.upscayl.run_command")
    @patch("upscayl_video.upscayl.ffmpeg_make_test_png")
    def test_smoke_success(self, make_png, run):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            make_png.side_effect = lambda path: path.write_bytes(b"png")
            run.return_value.returncode = 0
            paths = UpscaylPaths(Path("upscayl-bin"), root)
            ok, detail = smoke_test(paths, "upscayl-lite-4x", 128, None, Logger(quiet=True))
            self.assertTrue(ok, detail)

    @patch("upscayl_video.upscayl.run_command")
    @patch("upscayl_video.upscayl.ffmpeg_make_test_png")
    def test_smoke_failure_reports_stderr(self, make_png, run):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            make_png.side_effect = lambda path: path.write_bytes(b"png")
            run.side_effect = CommandError("vkEnumeratePhysicalDevices failed 5")
            paths = UpscaylPaths(Path("upscayl-bin"), root)
            ok, detail = smoke_test(paths, "upscayl-lite-4x", 128, None, Logger(quiet=True))
            self.assertFalse(ok)
            self.assertIn("vkEnumeratePhysicalDevices", detail)


class TestDoctorUpscayl(unittest.TestCase):
    @patch("upscayl_video.doctor.discover_upscayl", side_effect=DependencyError("missing"))
    def test_missing_upscayl_is_warn(self, _discover):
        cfg = load_config(None, overrides={"ffmpeg": sys.executable, "ffprobe": sys.executable})
        results = check_upscayl(cfg, skip_smoke=True, logger=Logger(quiet=True))
        self.assertTrue(any(r.status == "WARN" for r in results))

    @patch("upscayl_video.doctor.discover_upscayl", return_value=UpscaylPaths(Path("upscayl-bin"), Path("models")))
    @patch("upscayl_video.doctor.smoke_test", return_value=(False, "vkEnumeratePhysicalDevices failed 5"))
    def test_smoke_failure_is_fail(self, _smoke, _discover):
        cfg = load_config(None, overrides={"ffmpeg": sys.executable, "ffprobe": sys.executable})
        results = check_upscayl(cfg, skip_smoke=False, logger=Logger(quiet=True))
        self.assertTrue(any(r.status == "FAIL" for r in results))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest tests.test_doctor_upscayl -v`
Expected: FAIL because `smoke_test`/`check_upscayl` are missing.

- [ ] **Step 3: Implement smoke test/doctor**

- `ffmpeg_make_test_png(path)`: use FFmpeg `-f lavfi -i color=c=gray:s=64x64 -frames:v 1`; in tests patched.
- `smoke_test`: temp dir; create `in/test.png`, `out/`; run `upscayl-bin -i in -o out -m models -n <model> -s 2 -f png -c 0 -g 0 -t <tile>`, with `VK_ICD_FILENAMES` if `icd`; verify output exists and size > 0; return `(True, "OK")`; on failure return `(False, stderr tail + ISS)`. Clean up temp.
- `doctor.check_upscayl`:
  - discover; missing → WARN (split/assemble still work).
  - models list; missing → WARN.
  - smoke (unless skip) → FAIL with the exact error; if it fails and an NVIDIA ICD exists but the configured ICD was none/other, retry once with NVIDIA ICD and report the workaround.
  - Add `CheckResult` statuses; `run_doctor` returns 6 if any Upscayl FAIL, 3 for FFmpeg required, 5 disk.
- CLI `doctor` passes `skip_upscayl_smoke`.
- Real integration test: find Upscayl; skip if missing/WSI; create a 64x64 PNG with FFmpeg; run smoke; assert true. This test must be skipped on machines without a Vulkan GPU.

- [ ] **Step 4: Run tests**

Run:
- `python -m unittest tests.test_doctor_upscayl -v`
- `python -m unittest tests.test_doctor -v`
- `python -m unittest tests.integration.test_upscale_real -v`

Expected: unit tests PASS; real test PASS or SKIP with a clear reason.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/upscayl.py src/upscayl_video/doctor.py src/upscayl_video/cli.py tests/test_doctor_upscayl.py tests/integration/test_upscale_real.py
git commit -m "feat: add Upscayl smoke test and doctor checks"
```

---

### Task 3: Batch upscaler core

**Files:**
- Create: `src/upscayl_video/progress.py`
- Modify: `src/upscayl_video/upscayl.py`
- Create: `tests/test_upscayl_batch.py`
- Create: `tests/test_progress.py`
- Create: `tests/fixtures/fake_upscayl.py`
- Modify: `tests/util.py` (fake upscaler/model helpers)

**Interfaces:**
- Consumes: `frames.scan_frames`, `job.Job`, `upscayl.UpscaylPaths`, `util.run_command`.
- Produces:
  - `progress.Progress(total: int, label: str)` with `update(n)`, `done`, `elapsed`, `rate`, `eta_seconds`, `line()`.
  - `upscayl.upscale_frames(job: Job, paths: UpscaylPaths, *, model: str, scale: int, output_dir: Path, tile: int, batch_size: int, gpu: int, icd: Path | None, threads: str, retry: int, logger: Logger) -> int`.
  - `upscayl.missing_indices(source_dir: Path, output_dir: Path, total: int) -> list[int]`.
  - `upscayl.batch_outputs(input_dir: Path, output_dir: Path) -> dict[str, Path]`.

- [ ] **Step 1: Write the failing batch tests**

```python
# tests/test_upscayl_batch.py
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.job import Job
from upscayl_video.progress import Progress
from upscayl_video.upscayl import UpscaylPaths, missing_indices, upscale_frames
from upscayl_video.util import Logger


class TestMissing(unittest.TestCase):
    def test_missing_indices(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src = root / "frames"
            out = root / "upscaled"
            src.mkdir()
            out.mkdir()
            for i in (1, 2, 3):
                (src / f"frame_{i:08d}.png").write_bytes(b"x")
            (out / "frame_00000001.png").write_bytes(b"y")
            (out / "frame_00000002.png").write_bytes(b"")
            self.assertEqual(missing_indices(src, out, 3), [2, 3])


class TestProgressBasics(unittest.TestCase):
    def test_counts_and_line(self):
        p = Progress("upscale", 10)
        p.update(3)
        self.assertEqual(p.done, 3)
        self.assertIn("3/10", p.line())


class TestBatch(unittest.TestCase):
    def test_upscale_calls_batches_and_moves_outputs(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            job_dir = root / "job"
            job_dir.mkdir()
            (job_dir / "job.txt").write_text("source=x\n", encoding="utf-8")
            job = Job.load(job_dir)
            job.set("frame_count", "3")
            job.frames_dir.mkdir()
            for i in (1, 2, 3):
                (job.frames_dir / f"frame_{i:08d}.png").write_bytes(b"x")
            models = root / "models"
            models.mkdir()
            (models / "m.param").write_text("x", encoding="utf-8")
            (models / "m.bin").write_bytes(b"x")
            paths = UpscaylPaths(Path("upscayl-bin"), models)
            calls = []

            def fake_run(args, **kwargs):
                calls.append(args)
                in_dir = Path(args[args.index("-i") + 1])
                out_dir = Path(args[args.index("-o") + 1])
                for src in in_dir.iterdir():
                    (out_dir / src.name).write_bytes(b"up")
                return type("R", (), {"returncode": 0, "stderr": "", "stdout": ""})()

            with patch("upscayl_video.upscayl.run_command", side_effect=fake_run):
                count = upscale_frames(
                    job, paths, model="m", scale=2, output_dir=job.upscaled_dir,
                    tile=128, batch_size=2, gpu=0, icd=None, threads="1:2:2",
                    retry=1, logger=Logger(quiet=True),
                )
            self.assertEqual(count, 3)
            self.assertEqual(len(calls), 2)
            self.assertEqual(len(list(job.upscaled_dir.glob("*.png"))), 3)
            self.assertEqual(list(job.path.glob("batch_*")), [])
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m unittest tests.test_upscayl_batch -v`
Expected: FAIL because `missing_indices`/`upscale_frames` are missing.

- [ ] **Step 3: Implement batch core**

- `missing_indices`: scan source frames (any supported extension), require size > 0; scan output by leading `frame_<8 digits>` stem; an output is valid only if size > 0; return sorted missing 1..total.
- `upscale_frames`:
  - Ensure output dir exists.
  - Loop while missing:
    - pick first `batch_size`.
    - create `job.path / batch_NNNN / in|out`; hardlink/copy selected frames into `in`.
    - run `upscayl-bin -i in -o out -m models -n model -s scale -f png -c 0 -g gpu -t tile -j threads`; set `VK_ICD_FILENAMES` for the child only; cwd = binary parent.
    - verify every input has an output with size > 0, matching by stem (input `.jpg` may produce `.png`).
    - move outputs into target; remove batch dir.
    - update `Progress`; print every batch (count, rate, ETA).
  - On failure: if `retry>0`, halve tile (min 64) and batch (min 1), log, retry once; if still fails, raise `UpscaleError` with stderr tail and keep batch dir for debugging.
  - Do not use `shell=True`; pass absolute paths.
- `progress.Progress`: total, done, start monotonic; update; rate; ETA; line `"model: 120/1800 (6.7%) 0.42 fps ETA 01:06:40"`. Tests for math.
- Fake upscaler: a Python script that parses `-i/-o`, copies each input to output; on Windows a `.bat` wrapper; on Unix a `chmod +x` shell wrapper. Add `tests.util.make_fake_upscaler(root) -> Path` and `make_fake_models(root) -> Path`; both create the files and return the path. Tests can call `upscale_frames` with this path or mock `run_command`. Prefer the fake executable for the integration path; mock for command-shape unit tests.
- Batch names sanitize; never delete target outputs.

- [ ] **Step 4: Run tests**

Run:
- `python -m unittest tests.test_upscayl_batch -v`
- `python -m unittest tests.test_progress -v`

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/upscayl.py src/upscayl_video/progress.py tests/test_upscayl_batch.py tests/test_progress.py tests/fixtures/fake_upscayl.py
git commit -m "feat: batch upscale frames with resume"
```

---

### Task 4: Batch retry, memory-leak safety, and status counts

**Files:**
- Modify: `src/upscayl_video/upscayl.py`
- Modify: `src/upscayl_video/pipeline.py`
- Modify: `src/upscayl_video/cli.py`
- Create: `tests/test_upscayl_retry.py`
- Create: `tests/test_upscale_pipeline.py`

**Interfaces:**
- Consumes: Task 3.
- Produces:
  - `upscayl._oom_like(stderr: str) -> bool`.
  - `upscayl.retry_settings(tile: int, batch_size: int, attempt: int) -> tuple[int, int]`.
  - `pipeline.run_upscale(jobs, config, options, logger, *, dry_run=False) -> list[Job]`.
  - `pipeline.UpscaleOptions` dataclass.

- [ ] **Step 1: Write failing retry tests**

```python
import unittest
from upscayl_video.upscayl import _oom_like, retry_settings

class TestRetry(unittest.TestCase):
    def test_oom_like(self):
        self.assertTrue(_oom_like("vkAllocateMemory failed"))
        self.assertTrue(_oom_like("out of memory"))
        self.assertFalse(_oom_like("model not found"))

    def test_retry_halves(self):
        self.assertEqual(retry_settings(256, 100, 1), (128, 50))
        self.assertEqual(retry_settings(128, 1, 1), (64, 1))
        self.assertEqual(retry_settings(64, 1, 2), (64, 1))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m unittest tests.test_upscayl_retry -v`
Expected: FAIL.

- [ ] **Step 3: Implement retry and `run_upscale`**

- `_oom_like`: case-insensitive substrings `out of memory`, `vkallocatememory`, `vk_error_out_of_device_memory`, `cuda error`, `invalid gpu device` (the last one should be treated as an ICD/GPU error, not retryable indefinitely; keep separate).
- `retry_settings`: attempt 1 halves tile (min 64) and batch (min 1); attempt ≥2 returns unchanged.
- `UpscaleOptions`: model, scale, gpu, tile, batch_size, threads, icd, upscayl_bin, models_dir, upscaled_dir, retry, force.
- `run_upscale`:
  - For each job: load/probe? Upscale doesn't need media. Validate job frame_count and source.
  - Discover Upscayl; validate model in list; model/scale change vs `job.txt` requires `--force`; if force, clear `upscaled/` and `.done_upscale`.
  - `--upscaled-dir` override; default `job.upscaled_dir`.
  - `upscale_frames`; update `model`, `scale`, `upscaled_count`, `tile`, `batch_size`, `decode`? (decode is split), save, mark `.done_upscale`.
  - If frames missing, exit 4.
  - `--dry-run` prints plan.
- CLI `upscale` with options; `--all`.
- Tests: fake upscaler; model mismatch; missing frames; dry-run no output.

- [ ] **Step 4: Run tests**

Run:
- `python -m unittest tests.test_upscayl_retry tests.test_upscale_pipeline -v`
- Full suite.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/upscayl.py src/upscayl_video/pipeline.py src/upscayl_video/cli.py tests/test_upscayl_retry.py tests/test_upscale_pipeline.py
git commit -m "feat: add upscale command with retry and resume"
```

---

### Task 5: `run` all-in-one and multi-video summary

**Files:**
- Modify: `src/upscayl_video/pipeline.py`
- Modify: `src/upscayl_video/cli.py`
- Create: `tests/test_run_pipeline.py`

**Interfaces:**
- Consumes: `run_split`, `run_upscale`, `run_assemble`, `resolve_inputs`.
- Produces:
  - `pipeline.RunOptions(split: SplitOptions, upscale: UpscaleOptions, encode: EncodeOptions, cleanup: bool, stop_on_error: bool, chunk_seconds: str)`.
  - `pipeline.RunResult(input_path: Path, job: Job | None, output: Path | None, error: str | None)`.
  - `pipeline.run_all(inputs, config, options, logger) -> list[RunResult]`.

- [ ] **Step 1: Write failing run tests**

```python
# tests/test_run_pipeline.py
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.config import load_config
from upscayl_video.encode import EncodeOptions
from upscayl_video.pipeline import RunOptions, SplitOptions, UpscaleOptions, run_all
from upscayl_video.util import Logger
from tests.util import find_ffprobe, make_clip, make_fake_models, make_fake_upscaler


class TestRun(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = __import__("shutil").which("ffmpeg")
        if cls.ffmpeg is None:
            raise unittest.SkipTest("ffmpeg not available")
        cls.td = tempfile.TemporaryDirectory()
        cls.root = Path(cls.td.name)
        cls.a = cls.root / "a.mp4"
        cls.b = cls.root / "b.mp4"
        make_clip(cls.ffmpeg, cls.a, duration=1.0, size="160x120", fps=30)
        make_clip(cls.ffmpeg, cls.b, duration=1.0, size="160x120", fps=30)

    @classmethod
    def tearDownClass(cls):
        cls.td.cleanup()

    def test_run_two_videos_with_fake_upscaler(self):
        fake_bin = make_fake_upscaler(self.root / "fake")
        fake_models = make_fake_models(self.root / "fake-models")
        cfg = load_config(None, overrides={
            "ffmpeg": self.ffmpeg,
            "ffprobe": find_ffprobe(self.ffmpeg),
            "work_dir": str(self.root / "work"),
            "upscayl_bin": str(fake_bin),
            "models_dir": str(fake_models),
        })
        options = RunOptions(
            split=SplitOptions(fps=None, start=None, end=None, format="png",
                jpeg_quality=1, png_compression=3, denoise="none", tonemap=False,
                decode="cpu", scale=2, target_height=None,
                model="upscayl-standard-4x", verify_frames=False, recursive=False,
                force=False),
            upscale=UpscaleOptions(model="upscayl-standard-4x", scale=2),
            encode=EncodeOptions(encoder="cpu", preset="mp4-h264"),
            cleanup=False, stop_on_error=False, chunk_seconds="0",
        )
        results = run_all([self.a, self.b], cfg, options, Logger(quiet=True))
        self.assertEqual(len(results), 2)
        self.assertTrue(all(result.output and result.output.exists() for result in results))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m unittest tests.test_run_pipeline -v`
Expected: FAIL because `run_all` is missing.

- [ ] **Step 3: Implement `run_all`**

- For each input: `run_split` (reuse job if markers), `run_upscale`, `run_assemble`.
- Continue after a failure by default; `--stop-on-error` breaks.
- Record `RunResult`; print summary table `INPUT → OUTPUT STATUS ELAPSED`.
- If a job is chunked (has chunk markers), use Task 8/9 path instead; for now error if `chunk_seconds != "0"` (until Task 9).
- `--cleanup` after successful assemble.
- Update CLI `run` with all split/upscale/assemble options and `--stop-on-error`, `--recursive`, `--chunk-seconds`.
- Tests with fake upscaler; one bad input continues.

- [ ] **Step 4: Run tests and full suite**

Run:
- `python -m unittest tests.test_run_pipeline -v`
- `python -m unittest discover -s tests -q`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/pipeline.py src/upscayl_video/cli.py tests/test_run_pipeline.py
git commit -m "feat: add all-in-one run command"
```

---

### Task 6: Progress and ETA for upscale/encode

**Files:**
- Modify: `src/upscayl_video/progress.py`
- Modify: `src/upscayl_video/upscayl.py`
- Modify: `src/upscayl_video/pipeline.py`
- Modify: `tests/test_progress.py`

**Interfaces:**
- Produces:
  - `progress.Progress(label, total)` with `update`, `rate`, `eta_seconds`, `line`.
  - `progress.format_eta(seconds) -> str` (`HH:MM:SS`).
  - `upscayl.upscale_frames(..., progress: Progress | None)`.
  - `pipeline.run_upscale` prints batch progress and an ETA warning before starting if the first batch extrapolates > 1 h / > 12 h.

- [ ] **Step 1: Write failing progress tests**

```python
class TestProgress(unittest.TestCase):
    def test_eta(self):
        p = Progress("upscale", 100)
        p._started -= 10  # deterministic in test
        p.update(20)
        self.assertAlmostEqual(p.rate, 2.0, places=1)
        self.assertAlmostEqual(p.eta_seconds, 40.0, delta=2.0)
        self.assertIn("20/100", p.line())

    def test_format_eta(self):
        self.assertEqual(format_eta(0), "00:00:00")
        self.assertEqual(format_eta(3723), "01:02:03")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m unittest tests.test_progress -v`
Expected: FAIL.

- [ ] **Step 3: Implement progress and warnings**

- `Progress` uses `time.monotonic`; `_started` private for tests; update; rate = done/elapsed; ETA = (total-done)/rate.
- Print at most once per 5 seconds or per batch, not per frame.
- `run_upscale` starts a `Progress(total=frame_count)`, updates after each batch.
- Before a job, estimate ETA from the first batch; if > 1 h, warn; if > 12 h, ask for confirmation unless `--yes`.
- FFmpeg encode progress remains stage-level (`Encoding...`), because `run_command` buffers; document that ETA is available for the Upscayl stage. Do not claim frame-level FFmpeg progress.
- Tests use deterministic monotonic patching.

- [ ] **Step 4: Run tests**

Run:
- `python -m unittest tests.test_progress tests.test_upscayl_batch -v`
- Full suite.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/progress.py src/upscayl_video/upscayl.py src/upscayl_video/pipeline.py tests/test_progress.py
git commit -m "feat: add upscale progress and ETA"
```

---

### Task 7: Chunk planning and video-only segment encoding

**Files:**
- Create: `src/upscayl_video/chunking.py`
- Modify: `src/upscayl_video/encode.py`
- Create: `tests/test_chunking.py`

**Interfaces:**
- Produces:
  - `chunking.Chunk(index: int, start: float, end: float, start_frame: int, frame_count: int)`.
  - `chunking.plan_chunks(duration: float, fps: float, chunk_seconds: int) -> list[Chunk]`.
  - `chunking.concat_list(segments: Sequence[Path], path: Path) -> Path`.
  - `chunking.concat_segments(ffmpeg: Path, segments, output: Path, logger: Logger) -> None`.
  - `encode.build_segment_command(job, frame_set, media, preset, encoder, options, output, *, frame_width, frame_height) -> list[str]`.

- [ ] **Step 1: Write failing chunk tests**

```python
class TestChunkPlan(unittest.TestCase):
    def test_exact_boundaries(self):
        chunks = plan_chunks(30.0, 30.0, 10)
        self.assertEqual([(c.start_frame, c.frame_count) for c in chunks],
                         [(1, 300), (301, 300), (601, 300)])
        self.assertEqual(chunks[-1].end, 30.0)

    def test_no_lost_frames(self):
        chunks = plan_chunks(10.0, 29.97, 10)
        self.assertEqual(sum(c.frame_count for c in chunks), 300)

    def test_minimum_chunk(self):
        with self.assertRaises(ValidationError):
            plan_chunks(10.0, 30.0, 5)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m unittest tests.test_chunking -v`
Expected: FAIL.

- [ ] **Step 3: Implement chunk planning and segment command**

- `plan_chunks`: require `chunk_seconds >= 10`; `start_frame = round(start*fps)+1`; `end_frame = round(end*fps)`; `frame_count = end_frame - start_frame + 1`; final chunk ends at `round(duration*fps)`; no overlaps/gaps. Use cumulative rounding; assert sum == round(duration*fps) in tests.
- `build_segment_command`: like `build_assemble_command` but video-only:
  - `-framerate`, `-start_number`, `-i frames`, `-map 0:v:0`, `-an -sn -dn`,
  - video codec args, `-vf` target/range, color tags, `-metadata:s:v:0 rotate=0`,
  - container: `.ts` for H.264/HEVC (`-f mpegts`), `.mov` for ProRes.
  - no source input, no audio/subtitles, no `-shortest`.
- `concat_list`: write `file '<absolute>'\n` with forward slashes/escaped quotes.
- `concat_segments`: `ffmpeg -f concat -safe 0 -i list -c copy -fflags +genpts output`; if fails, try `.mkv` output and raise `EncodeError` with guidance to disable chunking.
- Tests use real FFmpeg for two 1s segments encoded CPU, concat, probe duration; skip if ffmpeg missing.
- Tests for chunk math independent of FFmpeg.

- [ ] **Step 4: Run tests**

Run:
- `python -m unittest tests.test_chunking -v`
- Full suite.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/chunking.py src/upscayl_video/encode.py tests/test_chunking.py
git commit -m "feat: plan chunks and encode video segments"
```

---

### Task 8: Chunked `run` orchestration

**Files:**
- Modify: `src/upscayl_video/pipeline.py`
- Modify: `src/upscayl_video/cli.py`
- Create: `tests/integration/test_run_chunked.py`

**Interfaces:**
- Consumes: `chunking.plan_chunks`, `frames.build_split_command`, `upscayl.upscale_frames`, `encode.build_segment_command`, `chunking.concat_segments`.
- Produces:
  - `pipeline.run_all(..., chunk_seconds)` implements per-chunk loop.
  - `pipeline._run_chunked(job, config, options, logger) -> Path`.

- [ ] **Step 1: Write failing chunked integration test**

```python
class TestChunkedRun(unittest.TestCase):
    def test_two_chunks_audio_sync(self):
        # 20 s, 320x240, 30 fps, AAC; fake upscaler; chunk 10 s
        # run_all -> output; ffprobe duration 20.0 +/- 0.2; audio present
        ...
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m unittest tests.integration.test_run_chunked -v`
Expected: FAIL because chunked `run_all` is missing.

- [ ] **Step 3: Implement chunked run**

- If `chunk_seconds == 0`, Task 5 path.
- If `auto`, use the design estimate/`max_work_gb`/free-space decision; choose 60 s when enabled.
- For each chunk:
  - `chunk_dir = job.chunks_dir / f"chunk_{i:04d}"`.
  - Extract frames into `chunk_dir/frames` with `build_split_command` using `start`, `duration`, `first_frame=1`, `frame_limit=chunk.frame_count`.
  - Upscale `chunk_dir/frames` → `chunk_dir/upscaled` via `upscayl.upscale_frames`; the job's frame_count is not used for chunk jobs.
  - Encode video-only segment via `build_segment_command`.
  - Validate segment duration/fps; write `.done_chunk_0001`.
  - Delete chunk frames/upscaled unless `--keep-chunks`.
- After all chunks: write concat list; concat to `chunks/concat.ts`; mux source audio/subs with `-t job.duration`; validate output; atomic replace; mark assemble; cleanup.
- `split`/`upscale`/`assemble` refuse chunked jobs (chunk markers present); `run` resumes.
- `run` with a non-chunked `.done_split` uses existing frames and does not rechunk; `--force` re-splits.
- Tests: fake upscaler, 20 s clip, 10 s chunks; output duration ±0.2; audio present; chunk dirs cleaned.
- Test concat failure path? Mock `run_command`; ensure error message suggests `--chunk-seconds 0`.

- [ ] **Step 4: Run tests and full suite**

Run:
- `python -m unittest tests.integration.test_run_chunked -v`
- `python -m unittest discover -s tests -q`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/pipeline.py src/upscayl_video/cli.py tests/integration/test_run_chunked.py
git commit -m "feat: add chunked run and concatenation"
```

---

### Task 9: Chunk resume, cleanup, and ETA warning

**Files:**
- Modify: `src/upscayl_video/pipeline.py`
- Modify: `src/upscayl_video/cli.py`
- Create: `tests/test_chunk_resume.py`

**Interfaces:**
- Consumes: Task 8.
- Produces:
  - Resume skips `.done_chunk_*`; incomplete chunks restart.
  - `--keep-chunks`, `--cleanup`, `--max-work-gb`, `--min-free-gb` behavior.
  - Disk check before each chunk; abort with exit 5 if below floor.

- [ ] **Step 1: Write failing resume/cleanup tests**

```python
class TestChunkResume(unittest.TestCase):
    def test_done_chunks_are_skipped(self):
        # create chunk_0001 segment + marker, chunk_0002 missing; run; assert only 0002 encoded
        ...

    def test_keep_chunks(self):
        # run with keep -> chunk dirs exist; without -> gone
        ...

    def test_low_disk_aborts(self):
        # patch free_bytes -> 0; run chunked; assert DiskSpaceError
        ...
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m unittest tests.test_chunk_resume -v`
Expected: FAIL.

- [ ] **Step 3: Implement resume/cleanup**

- Before each chunk, if segment exists and marker exists and `ffprobe` duration > 0, skip.
- If a segment exists without a marker, validate it; if invalid, delete/redo.
- Free-space check before each chunk; if `< min_free_gb`, raise `DiskSpaceError`.
- `--keep-chunks` keeps chunk dirs and segments; default deletes frames/upscaled but keeps segments until final.
- `--cleanup` deletes `chunks/`, `frames/`, `upscaled/`, `sequence/` after success.
- `run` prints chunk count and ETA; warning if >12h.
- Tests with fake upscaler and short clips; no real GPU.

- [ ] **Step 4: Run tests and full suite**

Run:
- `python -m unittest tests.test_chunk_resume -v`
- `python -m unittest discover -s tests -q`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/pipeline.py src/upscayl_video/cli.py tests/test_chunk_resume.py
git commit -m "feat: resume and clean chunked jobs"
```

---

### Task 10: Full doctor and encoder smoke tests

**Files:**
- Modify: `src/upscayl_video/doctor.py`
- Modify: `src/upscayl_video/cli.py`
- Create: `tests/test_doctor_encoders.py`

**Interfaces:**
- Produces:
  - `doctor.check_encoders` runs a 1-frame smoke test for each available encoder.
  - `doctor.run_doctor` exit 6 for Upscayl smoke failure; 3 required FFmpeg; 5 disk.
  - `--skip-upscayl-smoke` honored.

- [ ] **Step 1: Write failing encoder smoke tests**

```python
class TestEncoderSmoke(unittest.TestCase):
    def test_available_encoder_smoke(self):
        # patch ffmpeg -encoders output and run_command; assert OK/FAIL per encoder
        ...
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m unittest tests.test_doctor_encoders -v`
Expected: FAIL.

- [ ] **Step 3: Implement encoder smoke tests**

- For each encoder present, run a 1-frame `-f lavfi color` encode to `NUL`/`/dev/null`; report OK/FAIL.
- Cache results per ffmpeg path/mtime in a module dict; `assemble` auto already probes availability; doctor is diagnostic.
- `doctor` includes Upscayl checks from Task 2.
- Tests mock `run_command` and assert statuses; real `doctor` manual QA.

- [ ] **Step 4: Run tests and full suite**

Run:
- `python -m unittest tests.test_doctor_encoders tests.test_doctor -v`
- Full suite.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/doctor.py src/upscayl_video/cli.py tests/test_doctor_encoders.py
git commit -m "feat: smoke-test encoders in doctor"
```

---

### Task 11: Full 9-option menu

**Files:**
- Modify: `src/upscayl_video/menu.py`
- Create: `tests/test_menu_full.py`

**Interfaces:**
- Produces:
  - Menu options: 1 Run all, 2 Split, 3 Upscale, 4 Assemble, 5 Status, 6 Doctor, 7 Clean, 8 Settings, 9 Exit.
  - Settings prints config paths/values; no in-place editor required.
  - Clean asks for confirmation.
  - Ctrl+C returns 130.

- [ ] **Step 1: Write failing menu tests**

```python
class TestFullMenu(unittest.TestCase):
    def test_exit(self):
        with patch("builtins.input", side_effect=["9"]):
            self.assertEqual(run_menu(None, Logger(quiet=True)), 0)

    def test_settings_then_exit(self):
        with patch("builtins.input", side_effect=["8", "9"]):
            self.assertEqual(run_menu(None, Logger(quiet=True)), 0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m unittest tests.test_menu_full -v`
Expected: FAIL because option 8/9 behavior differs.

- [ ] **Step 3: Implement full menu**

- Add Run all and Upscale prompts; reuse `RunOptions`/`UpscaleOptions`.
- Settings prints config path, ffmpeg/upscayl paths, work dir, defaults; no editing.
- Clean confirmation.
- Catch `KeyboardInterrupt` around actions and return 130.
- Existing menu tests updated if option numbers changed; keep 9 exit.

- [ ] **Step 4: Run tests**

Run:
- `python -m unittest tests.test_menu_full tests.test_menu -v`
- Full suite.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/upscayl_video/menu.py tests/test_menu_full.py tests/test_menu.py
git commit -m "feat: complete the interactive menu"
```

---

### Task 12: Documentation and changelog

**Files:**
- Modify: `README.md`
- Modify: `docs/USAGE.md`
- Modify: `docs/TROUBLESHOOTING.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Update docs**

- README status: “V1 complete; V2 native planned in v2/”.
- Quick start: `run`, `upscale`, `run --chunk-seconds 60`.
- Usage: all new flags, model recommendations, tile/VRAM, chunking, ETA, `doctor`.
- Troubleshooting: Vulkan ICD, missing models, OOM, memory leak, chunk concat failure, low disk.
- Changelog: automation features.

- [ ] **Step 2: Run a docs link check**

Run a simple grep for broken relative links and `python upscayl-video.py --help`; expected exit 0.
- [ ] **Step 3: Commit**

```bash
git add README.md docs/USAGE.md docs/TROUBLESHOOTING.md CHANGELOG.md
git commit -m "docs: document automated upscaling and chunking"
```

---

### Task 13: Full integration matrix

**Files:**
- Create: `tests/integration/test_upscale_batch_fake.py`
- Create: `tests/integration/test_upscale_real.py` (if not already)
- Modify: `tests/fixtures/fake_upscayl.py`

- [ ] **Step 1: Test with fake upscaler**

- 60 frames, batch 10, delete 5 outputs, resume; assert 60.
- Simulate a batch leaving a zero-byte output; assert it is retried.
- Simulate a failed batch; assert tile/batch halved and one retry.
- Test model change requires `--force`; test `--dry-run`.

- [ ] **Step 2: Test with real Upscayl (conditional)**

- Skip if `upscayl-bin`/models/GPU unavailable.
- One 64×64 frame, `upscayl-lite-4x`, `-s 2`, assert output dimensions.
- A 5-frame batch with tile 128.
- `doctor` smoke test.

- [ ] **Step 3: Run all tests**

Run:
- `python -m unittest discover -s tests -v`
Expected: PASS or SKIP only for missing Upscayl/GPU.

- [ ] **Step 4: Commit**

```bash
git add tests/integration/test_upscale_batch_fake.py tests/integration/test_upscale_real.py tests/fixtures/fake_upscayl.py
git commit -m "test: cover automated upscale and chunked runs"
```

---

### Task 14: Final QA and V1 complete

- [ ] **Step 1: Full suite**

Run: `python -m unittest discover -s tests -q`
Expected: OK, no failures. Read the tail.

- [ ] **Step 2: Real QA**

- 1080p 3 s clip: `run --model upscayl-lite-4x --scale 2 --encoder auto`.
- Confirm output 4K, 90 frames, audio; `doctor`; status.
- Long clip 60 s with `--chunk-seconds 10`, fake/real upscaler; confirm duration/audio.
- `clean --all-intermediates`; status.

- [ ] **Step 3: Verify no regressions**

- Manual GUI workflow still works.
- `split --help`, `assemble --help`, `upscale --help`, `run --help`.
- `.bat`/`.sh` exit codes.

- [ ] **Step 4: Commit and tag**

```bash
git add CHANGELOG.md README.md
git commit -m "docs: mark V1 complete"
git tag -a v0.2.0-v1 -m "V1 complete: automated Upscayl, run, chunking"
```

Do not publish until the user asks.

---

## Self-Review

### Spec coverage for this plan

| Spec area | Task |
|---|---|
| Upscayl discovery/models/ICD/VRAM/tile | 1 |
| Upscayl smoke/doctor | 2 |
| Batch upscaling, hardlinks, resume, memory leak | 3 |
| Retry/OOM, `upscale` command | 4 |
| `run` all-in-one, multi-video | 5 |
| Progress/ETA | 6 |
| Chunk planning/segment encode | 7 |
| Chunked run, concat, audio mux | 8 |
| Chunk resume/cleanup/disk | 9 |
| Encoder smoke tests | 10 |
| Full menu | 11 |
| Docs | 12 |
| Fake/real integration | 13 |
| Final QA/tag | 14 |

Out of scope: V2 PowerShell/bash (plans 3–4), GUI, parallel GPU jobs, HDR output, frame interpolation, arbitrary scale factors, model downloads.

### Type consistency

- `UpscaylPaths`, `ModelInfo`, `UpscaleOptions`, `RunOptions`, `RunResult`, `Chunk` are defined once and reused.
- `run_upscale` returns `list[Job]`; `run_all` returns `list[RunResult]`.
- `run_all` uses existing `SplitOptions`/`EncodeOptions` unchanged; `RunOptions` composes them.
- `Progress` is optional in `upscale_frames` so unit tests don’t need it.
- Chunk frame counts sum to `round(duration*fps)`; assert in tests.

### Review Focus coverage

- Windows/AMD Vulkan: Tasks 1, 2, 12, 13.
- Memory leak/partial output: Tasks 3, 4, 13.
- VRAM/OOM: Tasks 1, 3, 4.
- Chunk boundaries/audio: Tasks 7, 8, 9, 13.
- Long-video disk/ETA: Tasks 6, 8, 9, 14.
- CLI/menu/doctor: Tasks 2, 4, 5, 10, 11, 13.

### Known deferred items

- Live frame-level FFmpeg encode progress: `run_command` buffers; only stage-level encode progress. Upscayl progress is per batch.
- Anamorphic correction (warning only), HDR output, VFR preservation.
- Real 4K/multi-hour QA is manual and machine-dependent.
- V2 parity: plans 3–4.
