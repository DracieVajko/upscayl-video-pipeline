# Upscayl Video Pipeline

A local FFmpeg + Upscayl pipeline for upscaling video:

```
video → frames → Upscayl → frames → video (with audio, subtitles, chapters)
```

**Status:** V1 core implemented. Split, manual Upscayl GUI upscaling, and
assemble work end-to-end. Automated `upscale`/`run`, chunking, and the
no-Python V2 implementation are the next plans.

## Repository layout

- **`/` (root): V1 core**, Python 3.10+ CLI and launchers. This is the working
  implementation today.
- **`v2/`: V2 native** (PowerShell 5.1+ and bash 3.2+), planned full-parity
  implementation. Not implemented yet; see [`v2/README.md`](v2/README.md).
- **`docs/`**: design spec, plans, usage, troubleshooting, and upstream notes.

Both versions share the same `job.txt` folder contract, so users can choose
the implementation that fits their machine without changing workflows.

- Design: [`docs/specs/2026-10-26-upscayl-video-pipeline-design.md`](docs/specs/2026-10-26-upscayl-video-pipeline-design.md)
- V1 core plan: [`docs/superpowers/plans/2026-10-26-upscayl-video-pipeline-v1-core.md`](docs/superpowers/plans/2026-10-26-upscayl-video-pipeline-v1-core.md)
- V1 automation plan: [`docs/superpowers/plans/2026-10-26-upscayl-video-pipeline-v1-automation.md`](docs/superpowers/plans/2026-10-26-upscayl-video-pipeline-v1-automation.md)
- Usage: [`docs/USAGE.md`](docs/USAGE.md)
- Troubleshooting: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)
- Mentioning it to Upscayl: [`docs/UPSTREAM.md`](docs/UPSTREAM.md)

## What works now

- One or many input videos, each with its own `work/<job>/` folder.
- Split to PNG or JPEG with optional denoise, HDR tonemapping, CFR conversion,
  resume, and a sample-based disk estimate.
- Manual batch upscaling in the Upscayl GUI.
- Assembling standard or Upscayl-suffixed frame names, including one-level
  output subfolders.
- MP4 H.264, MP4 HEVC, MKV HEVC, and MOV ProRes.
- NVIDIA NVENC, AMD AMF, or CPU encoding, with automatic fallback.
- Audio copy/AAC/PCM/none, multiple tracks on request, subtitles, chapters.
- `doctor`, `status`, `clean`, `--dry-run`, and a basic interactive menu.
- Paths with spaces and Unicode.

Not in this build: automated `upscayl-bin` invocation, `run`, chunking,
the full menu, and V2 PowerShell/bash parity.

## Requirements

- Python 3.10+ (V1 core).
- FFmpeg and ffprobe.
- Upscayl (for the manual GUI stage; not required by the CLI itself).

## Quick start

```bash
# Windows
upscayl-video.bat doctor --ffmpeg "C:\FFMPEG\ffmpeg.exe" --ffprobe "C:\FFMPEG\ffprobe.exe"

# Linux/macOS
./upscayl-video.sh doctor

# 1. Split
upscayl-video split "clip.mp4" --work-dir "D:\UpscaylVideo"

# 2. In Upscayl:
#    input  D:\UpscaylVideo\clip\frames
#    output D:\UpscaylVideo\clip\upscaled
#    choose a model and scale, run the batch

# 3. Assemble
upscayl-video assemble "D:\UpscaylVideo\clip" --preset mp4-h264 --encoder auto
```

See [`docs/USAGE.md`](docs/USAGE.md) for every command and flag.

## Configuration

Copy `config.example.txt` to `config.txt` and set `ffmpeg`, `ffprobe`, and
`work_dir`. CLI flags override the file. Put the work directory on a large
drive; 1080p PNG frames are commonly 1–3 MiB each.

## License

MIT. Upscayl is a separate AGPL-3.0 project; its models are not distributed here.
