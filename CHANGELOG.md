# Changelog

All notable changes to this project will be documented here.

## [0.3.0-v2] — 2026-10-27

### Added — V1 (Python reference)

- `doctor`, `split`, `assemble`, `upscale`, `run`, `status`, `clean`, and the
  full nine-option interactive menu.
- Frame extraction with PNG/JPEG, denoise, HDR tonemapping, CFR conversion,
  resume, and sample-based disk estimation.
- Manual Upscayl GUI workflow, including suffixed output names and one-level
  output subfolders.
- Automated `upscayl-bin` upscaling in resumable batches, with model/ICD/tile
  discovery and VRAM-based batch sizing.
- All-in-one `run` for one or many videos, with progress/ETA and long-run
  warnings.
- Time-based chunking for long videos, per-chunk encode, concat, and audio mux.
- MP4 H.264, MP4 HEVC, MKV HEVC, and MOV ProRes presets.
- NVIDIA NVENC, AMD AMF, and CPU encoding with automatic fallback.
- Audio copy/AAC/PCM/none, multiple audio tracks, subtitles, and chapters.
- Output validation with ffprobe and BT.709 color-tag normalization.
- Windows `.bat` and Unix `.sh` launchers, usage and troubleshooting docs.

### Added — V2 (no Python/Node/jq)

- Windows: `v2/windows/UpscaylVideo.ps1` (PowerShell 5.1+) and
  `UpscaylVideo.bat`.
- Unix: `v2/unix/upscayl-video.sh` (bash 3.2+).
- Same commands, flags, `job.txt`/`config.txt` contract, presets, audio and
  subtitle rules, exit codes, chunking, resume, doctor, and menu as V1.
- Plain PowerShell and bash test harnesses with no Pester/bats dependency.
- Cross-version parity harnesses: `v2/tests/Run-Parity.ps1` and
  `v2/tests/Run-Parity.sh`.

### Fixed

- Refuse to write the output over the source video; enforce the preset extension.
- Encode through a partial file and atomically replace the final output; delete
  partial files on failure and clear stale `.done_assemble` markers.
- Use the video duration (or packet count) instead of a fragile Matroska tail
  probe, so `--fps`, VFR, and audio-tail sources do not lose frames.
- Seek the source input with `-ss` for trimmed jobs; re-encode copied audio as
  AAC for a sample-accurate start.
- Honor a job's stored `--target-height`; round odd target heights up.
- Write BT.709 SDR color tags after `--tonemap`.
- Preserve subtitles and attachments during the color-tag remux, and avoid
  failing on MOV data tracks.
- Fall back from RGB color matrices (`gbr`) to a valid YUV matrix (BT.709 for
  HD, BT.601 for SD) instead of passing invalid encoder options.
- Convert `mov_text` subtitles to `subrip` in MKV instead of failing.
- Reject partial upscaled frame sets before encoding; never shrink `frame_count`.
- Build chunk segments with the job's stored `target_height`, not only the
  value repeated on the command line.
- Reject `--output FILE` with multiple `run` inputs instead of overwriting the
  first result.
- Re-splitting the same job without `--end` no longer reports a false settings
  difference.
- Resolve config-relative paths against the config directory and CLI-relative
  paths against the current directory.
- Treat an existing literal file/folder as a literal input before glob
  expansion, so names containing `[`, `]`, or `?` are not skipped.
- Bash: 25 fps and other non-30 sources, `--opt=value` parsing, chunked
  source state, `last_error`, `--stop-on-error` exit codes, empty arrays on
  bash 3.2, temp-file cleanup, and Git Bash path conversion.
- Use config `default_audio`/`default_subs`, delete transient `sequence/`, and
  return Windows `.bat` exit codes.

### Validated

- 176 V1 tests, 71 V2 PowerShell tests, and 82 V2 bash tests pass.
- V1: all three local example clips fully split and fully assembled (225, 556,
  2,495 frames; 7.53 s, 18.53 s, 83.15 s), real Upscayl on 1 s windows, a real
  18.5 s chunked run, and a full 83.15 s chunked run
  (2,495 frames, 2944×3904, 83.116689 s, AAC 83.105 s, BT.709).
- V2 PowerShell: real Upscayl runs on 0.5 s, 5 s (audio + subtitles), and 12 s
  chunked jobs; all presets, target height, 10-bit HEVC, odd dimensions, JPEG,
  trim, resume, and GUI-suffixed names.
- V2 bash on Git Bash: real Upscayl runs on 0.5 s, 5 s (audio + subtitles), and
  12 s chunked jobs; split/assemble variants and resume.
- V1 ↔ V2 PowerShell cross-version matrix passes on MP4, MKV+MP3+SRT+chapters,
  and odd-dimension FFV1.
- `doctor` green in V1 and both V2 implementations.

### Not yet

- `run --chunk-seconds auto` uses the non-chunked path in both versions; use an
  explicit value such as `60`.
- Native Linux/macOS execution of the bash implementation (validated on Git
  Bash for Windows and with bash 3.2 syntax checks only).
- Full real-Upscayl runs of the 7.5/18.5/83 s clips in V2 (validated on 0.5 s,
  5 s, and 12 s jobs, including chunking).
- A full real-Upscayl run of the 7.5 s V1 clip (validated as a 1 s window plus
  full split/assemble).

## Design

- Initial design specification and V1 core implementation plan.


