# V2 Native Parity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Implement V2 (no Python) with the same commands, flags, work folders, `job.txt` contract, and observable behavior as V1.

**Architecture:** One self-contained PowerShell 5.1+ script for Windows and one bash 3.2+ script for Linux/macOS, each with a thin launcher. Both use FFmpeg/ffprobe and `upscayl-bin` directly. They read/write the same `job.txt`/`config.txt` as V1 so jobs can cross versions.

**Tech Stack:** PowerShell 5.1+, bash 3.2+, FFmpeg/ffprobe, Upscayl CLI. No Python, Node, jq, or external modules.

**Spec:** `docs/specs/2026-10-26-upscayl-video-pipeline-design.md`

**V1 reference:** current `src/upscayl_video/` on `main`; validated in `docs/VALIDATION.md`.

---

## Global Constraints

- No Python/Node/jq dependency in V2.
- Same job layout, key=value contract, defaults, presets, audio/subtitle rules, exit codes, and safety rules as V1.
- Never overwrite the source; atomic temp output; clear `.done_assemble` before re-encode.
- Paths with spaces and Unicode must work on Windows and Unix.
- V2 must be tested against V1 jobs in both directions.
- Windows PowerShell 5.1 compatibility; macOS bash 3.2 compatibility (no associative arrays, no `mapfile`, no `${var,,}`).
- No publication of V2 until cross-version tests pass.

## File Map

| Path | Responsibility |
|---|---|
| `v2/windows/UpscaylVideo.ps1` | Windows full implementation |
| `v2/windows/UpscaylVideo.bat` | Windows launcher/menu entry |
| `v2/unix/upscayl-video.sh` | Unix full implementation |
| `v2/tests/fixtures/` | Cross-version fixtures |
| `v2/tests/run-parity.ps1` | Windows parity tests |
| `v2/tests/run-parity.sh` | Unix parity tests |
| `v2/README.md` | V2 usage and parity status |

## Tasks

### Task 1: Shared contract and parity harness

- [x] Fixtures: 2 s 160×120 H.264/AAC; MKV with MP3+SRT+chapters; 321×241 FFV1.
- [x] `run-parity` creates V1 jobs, assembles with V2, and the reverse.
- [x] Compare duration ±0.1 s, frame count, dimensions, audio, subtitle, color tags.
- [x] Commit.

### Task 2: PowerShell foundation

- [x] Launcher, `--version`, `--help`, config parser, `job.txt` reader/writer, atomic write.
- [x] `ffprobe` JSON parsing: duration/video tail, fps, streams, color, rotation, HDR.
- [x] Paths with spaces/Unicode, executable discovery.
- [x] `doctor` core checks.
- [x] Tests: contract parsing, fps, discovery.
- [x] Commit.

### Task 3: PowerShell split and assemble

- [x] Split: PNG/JPEG, CFR, resume, denoise, tonemap, disk estimate.
- [x] Assemble: presets, encoder auto NVENC/AMF/x264/x265, audio/subtitle plans, color/rotation, validation, temp output.
- [x] Frame sequence normalization for GUI-suffixed names.
- [x] Tests/real-media checks for MP4/MKV/ProRes, audio, subtitles, trim, target height.
- [x] Commit.

### Task 4: PowerShell upscale/run/chunking

- [x] Upscayl discovery/models/ICD/VRAM/tile/batch; batch resume/retry.
- [x] `upscale`, `run`, chunking, progress/ETA, cleanup.
- [x] Full 9-option menu.
- [x] Real Upscayl smoke and 12 s chunked run; 68 unit tests.
- [x] Commit.

### Task 5: Bash foundation

- [x] Launcher, config/job parser, ffprobe field parsing, path handling, atomic write.
- [x] `doctor` core checks.
- [x] Tests on Git Bash; bash 3.2 syntax constraints observed.
- [x] Commit.

### Task 6: Bash split and assemble

- [x] Same behavior as Task 3 using bash arrays/`awk`/`sed`/`find` (no jq).
- [x] Tests: output/job parity with V1, spaces/Unicode, audio/subtitles, presets.
- [x] Commit.

### Task 7: Bash upscale/run/chunking

- [x] Discovery/ICD/tile/batch, resume/retry, `upscale`, `run`, chunking, cleanup.
- [x] Full menu.
- [x] Real Upscayl 0.5/5/12 s runs under Git Bash; 63 tests.
- [x] Commit.

### Task 8: Cross-version matrix, docs, release

- [x] V1 split → V2 Windows assemble, V2 Windows split → V1 assemble (6/6).
- [ ] V1 split → V2 Unix assemble, V2 Unix split → V1 assemble — requires a
  native Unix V1 environment; not available in this Windows-only session.
  `Run-Parity.sh` verifies job/output property parity instead.
- [x] Compare V1/V2 outputs with ffprobe; documented differences and gaps.
- [x] Update `v2/README.md`, main README, VALIDATION, CHANGELOG.
- [x] Tag `v0.3.0-v2` after the Windows matrix and both V2 test suites passed;
  Unix native execution remains explicitly documented as unverified.
- [x] Owner approved implementation/publication in this session.

## Acceptance

- A user on a clean Windows machine with only PowerShell, FFmpeg, and Upscayl can run split/upscale/run/assemble/chunking.
- A user on Linux/macOS with bash, FFmpeg, and Upscayl can do the same.
- A job started in V1 can be finished in V2 and vice versa.
- No Python/Node/jq is invoked.
- Exit codes and safety behavior match V1.
