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

- [ ] Fixtures: one 2 s 160×120 H.264/AAC clip, one with MP3+SRT, one odd-dimension FFV1, one HLG 10-bit.
- [ ] `run-parity` creates a V1 job with `split`, then V2 `assemble`; and V2 `split`, V1 `assemble`.
- [ ] Compare duration ±0.1 s, frame count, dimensions, audio stream, subtitle stream, color tags.
- [ ] Commit.

### Task 2: PowerShell foundation

- [ ] Launcher, `--version`, `--help`, config parser, `job.txt` reader/writer, atomic write.
- [ ] `ffprobe` JSON parsing: duration/video tail, fps rational, streams, color, rotation, HDR.
- [ ] Paths with spaces/Unicode, executable discovery.
- [ ] `doctor` core checks.
- [ ] Tests: contract parsing, fps, discovery.
- [ ] Commit.

### Task 3: PowerShell split and assemble

- [ ] Split: frame extraction (PNG/JPEG), CFR, resume, denoise, tonemap, disk estimate.
- [ ] Assemble: presets, encoder auto NVENC/AMF/x264/x265, audio/subtitle plans, color/rotation, output validation, temp output.
- [ ] Frame sequence normalization for GUI-suffixed names.
- [ ] Tests: parity with V1 for MP4/MKV/ProRes, audio, subtitles, trim, target height.
- [ ] Commit.

### Task 4: PowerShell upscale/run/chunking

- [ ] Upscayl discovery/models/ICD/VRAM/tile/batch; batch resume/retry.
- [ ] `upscale`, `run`, chunking, progress/ETA, cleanup.
- [ ] Full 9-option menu.
- [ ] Tests: fake upscaler and real Upscayl smoke (conditional); chunked 20 s parity.
- [ ] Commit.

### Task 5: Bash foundation

- [ ] Launcher, config/job parser, ffprobe JSON via `-of default=nw=1` fields, path handling, atomic write.
- [ ] `doctor` core checks.
- [ ] Tests on Git Bash/Linux; macOS `bash 3.2` syntax constraints.
- [ ] Commit.

### Task 6: Bash split and assemble

- [ ] Same behavior as Task 3 using bash arrays/`awk`/`sed`/`find` (no jq).
- [ ] Tests: parity with V1/V2 Windows, spaces/Unicode, audio/subtitles, presets.
- [ ] Commit.

### Task 7: Bash upscale/run/chunking

- [ ] Discovery/ICD/tile/batch, resume/retry, `upscale`, `run`, chunking, cleanup.
- [ ] Full menu.
- [ ] Tests: fake upscaler; real Upscayl conditional; 20 s chunked parity.
- [ ] Commit.

### Task 8: Cross-version matrix, docs, release

- [ ] V1 split → V2 Windows assemble, V2 Windows split → V1 assemble.
- [ ] V1 split → V2 Unix assemble, V2 Unix split → V1 assemble.
- [ ] Compare V1/V2/V2 outputs with ffprobe; document known differences.
- [ ] Update `v2/README.md`, main README, USAGE, TROUBLESHOOTING, CHANGELOG.
- [ ] Tag `v0.3.0-v2` only after the matrix passes.
- [ ] Do not publish until the owner approves.

## Acceptance

- A user on a clean Windows machine with only PowerShell, FFmpeg, and Upscayl can run split/upscale/run/assemble/chunking.
- A user on Linux/macOS with bash, FFmpeg, and Upscayl can do the same.
- A job started in V1 can be finished in V2 and vice versa.
- No Python/Node/jq is invoked.
- Exit codes and safety behavior match V1.
