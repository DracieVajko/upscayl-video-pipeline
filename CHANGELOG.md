# Changelog

All notable changes to this project will be documented here.

## [Unreleased]

### Added

- V1 core pipeline: `doctor`, `split`, `assemble`, `status`, `clean`, and a
  basic interactive menu.
- Frame extraction with PNG/JPEG, denoise, HDR tonemapping, CFR conversion,
  resume, and sample-based disk estimation.
- Manual Upscayl GUI workflow, including suffixed output names and one-level
  output subfolders.
- MP4 H.264, MP4 HEVC, MKV HEVC, and MOV ProRes presets.
- NVIDIA NVENC, AMD AMF, and CPU encoding with automatic fallback.
- Audio copy/AAC/PCM/none, multiple audio tracks, subtitles, and chapters.
- Output validation with ffprobe.
- Windows `.bat` and Unix `.sh` launchers.
- Usage and troubleshooting documentation.

### Added

- Automated `upscayl-bin` upscaling in resumable batches, with model/ICD/tile
  discovery and VRAM-based batch sizing.
- `run` all-in-one command for one or many videos.
- Time-based chunking for long videos, per-chunk encode, concat, and audio mux.
- Upscayl smoke test and encoder smoke tests in `doctor`.
- Full nine-option interactive menu.
- Progress/ETA for the Upscayl stage and long-run warnings.

### Fixed

- Refuse to write the output over the source video; enforce the preset extension.
- Encode through a partial file and atomically replace the final output; delete
  partial files on failure and clear stale `.done_assemble` markers.
- Use video duration (tail packet probe when needed) instead of packet count, so
  `--fps`, VFR, and Matroska audio-tail sources do not lose frames.
- Seek the source input with `-ss` for trimmed jobs; re-encode copied audio as
  AAC for a sample-accurate start.
- Honor a job's stored `--target-height`; round odd target heights up.
- Write BT.709 SDR color tags after `--tonemap`.
- Convert `mov_text` subtitles to `subrip` in MKV instead of failing.
- Reject partial upscaled frame sets before encoding; never shrink `frame_count`.
- Resolve config-relative paths against the config directory and CLI-relative
  paths against the current directory.
- Use config `default_audio`/`default_subs`, delete transient `sequence/`, and
  return Windows `.bat` exit codes.

### Validated

- 170 automated tests pass.
- All three local example clips fully split and fully assembled: 225, 556,
  and 2,495 frames; durations 7.53 s, 18.53 s, and 83.15 s; AAC audio; BT.709.
- Real Upscayl `upscayl-lite-4x` runs on a 1-second window of each clip: 2×
  output, correct frame counts and audio.
- Real chunked run on an 18.5 s clip (`--chunk-seconds 10`): 2 chunks, 556
  frames, 3104×4128, correct audio, chunks cleaned.
- Full 83.15 s real Upscayl run (`--chunk-seconds 30`): 2,495 frames,
  2944×3904, 83.116689 s, AAC 83.105 s, BT.709, chunks cleaned.
- `doctor` green including the Upscayl smoke test and all encoder smoke tests.
- See `docs/VALIDATION.md` for exact results and the remaining gaps.

### Not yet

- Automated `upscale` and `run` commands.
- Chunking, ETA, and cleanup for long videos.
- Full menu.
- V2 PowerShell/bash parity.

## Design

- Initial design specification and V1 core implementation plan.
