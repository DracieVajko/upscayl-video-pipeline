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

### Not yet

- Automated `upscale` and `run` commands.
- Chunking, ETA, and cleanup for long videos.
- Full menu.
- V2 PowerShell/bash parity.

## Design

- Initial design specification and V1 core implementation plan.
