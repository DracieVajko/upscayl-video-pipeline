# Upscayl Video Pipeline

A local FFmpeg + Upscayl pipeline for upscaling video:

```
video → frames → Upscayl → frames → video (with audio, subtitles, chapters)
```

**Status:** V1 and V2 implemented. Split, manual GUI or automated
`upscayl-bin` upscaling, all-in-one `run`, chunked processing, and assemble
work end-to-end in both versions.

## Repository layout

- **`/` (root): V1 core**, Python 3.10+ CLI and launchers.
- **`v2/`: V2 native** (PowerShell 5.1+ for Windows, bash 3.2+ for Unix),
  no Python/Node/jq. See [`v2/README.md`](v2/README.md).
- **`docs/`**: design spec, plans, usage, troubleshooting, and upstream notes.

Both versions share the same `job.txt` folder contract, so users can choose
the implementation that fits their machine without changing workflows.

- Design: [`docs/specs/2026-10-26-upscayl-video-pipeline-design.md`](docs/specs/2026-10-26-upscayl-video-pipeline-design.md)
- V1 core plan: [`docs/superpowers/plans/2026-10-26-upscayl-video-pipeline-v1-core.md`](docs/superpowers/plans/2026-10-26-upscayl-video-pipeline-v1-core.md)
- V1 automation plan: [`docs/superpowers/plans/2026-10-26-upscayl-video-pipeline-v1-automation.md`](docs/superpowers/plans/2026-10-26-upscayl-video-pipeline-v1-automation.md)
- V2 parity plan: [`docs/superpowers/plans/2026-10-26-upscayl-video-pipeline-v2-parity.md`](docs/superpowers/plans/2026-10-26-upscayl-video-pipeline-v2-parity.md)
- Usage: [`docs/USAGE.md`](docs/USAGE.md)
- Troubleshooting: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)
- Validation record: [`docs/VALIDATION.md`](docs/VALIDATION.md)
- Mentioning it to Upscayl: [`docs/UPSTREAM.md`](docs/UPSTREAM.md)

## What works now

- One or many input videos, each with its own `work/<job>/` folder.
- Split to PNG or JPEG with optional denoise, HDR tonemapping, CFR conversion,
  resume, and a sample-based disk estimate.
- Manual batch upscaling in the Upscayl GUI.
- Automated `upscayl-bin` upscaling in bounded, resumable batches.
- All-in-one `run`: split → upscale → assemble, one or many videos.
- Time-based chunking for long videos, with resume and cleanup.
- Assembling standard or Upscayl-suffixed frame names, including one-level
  output subfolders.
- MP4 H.264, MP4 HEVC, MKV HEVC, and MOV ProRes.
- NVIDIA NVENC, AMD AMF, or CPU encoding, with automatic fallback.
- Audio copy/AAC/PCM/none, multiple tracks on request, subtitles, chapters.
- `doctor`, `upscale`, `run`, `status`, `clean`, `--dry-run`, and the full
  nine-option menu.
- Windows/NVIDIA Vulkan ICD workaround for the AMD enumeration bug.
- Paths with spaces and Unicode.
- **V2 parity:** the same commands, flags, `job.txt`/`config.txt` contract,
  presets, audio/subtitle rules, exit codes, chunking, resume, doctor, and
  nine-option menu in PowerShell and bash.

Known limitation: `run --chunk-seconds auto` currently uses the non-chunked
path in both versions; use an explicit value such as `60` for chunking. V2
bash has been exercised on Git Bash for Windows and with syntax checks for
bash 3.2, but not on native Linux/macOS. Details in
[`docs/VALIDATION.md`](docs/VALIDATION.md).

## Requirements

- **V1:** Python 3.10+.
- **V2 Windows:** PowerShell 5.1+.
- **V2 Unix:** bash 3.2+.
- FFmpeg and ffprobe.
- Upscayl with `upscayl-bin` and models for `upscale`/`run`; split/assemble and
  the manual GUI workflow do not require the CLI.

## Install

There is no package to install; both versions run from the checkout.

```bash
git clone https://github.com/DracieVajko/upscayl-video-pipeline.git
cd upscayl-video-pipeline
cp config.example.txt config.txt   # optional; config.txt is gitignored
```

V1 needs Python 3.10+. V2 needs PowerShell 5.1+ (Windows) or bash 3.2+
(Linux/macOS). Point `ffmpeg`, `ffprobe`, `upscayl_bin`, and `models_dir` at
your installation in `config.txt`, or pass the corresponding flags.

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

# Or do everything automatically with Upscayl CLI
upscayl-video run "clip.mp4" --model upscayl-lite-4x --scale 2 --preset mp4-h264

# Long video: chunked run (explicit chunk length)
upscayl-video run "movie.mkv" --chunk-seconds 60 --preset mkv-hevc --cleanup
```

V2 uses the same commands and flags:

```bat
:: Windows (PowerShell 5.1+)
v2\windows\UpscaylVideo.bat doctor
v2\windows\UpscaylVideo.bat run "clip.mp4" --preset mp4-hevc
```

```bash
# Linux/macOS (bash 3.2+)
bash v2/unix/upscayl-video.sh doctor
bash v2/unix/upscayl-video.sh run "clip.mp4" --preset mp4-hevc
```

See [`docs/USAGE.md`](docs/USAGE.md) for every command and flag and
[`v2/README.md`](v2/README.md) for V2 parity details.

## Configuration

Copy `config.example.txt` to `config.txt` and set `ffmpeg`, `ffprobe`, and
`work_dir`. CLI flags override the file. Put the work directory on a large
drive; 1080p PNG frames are commonly 1–3 MiB each.

## License

MIT. Upscayl is a separate AGPL-3.0 project; its models are not distributed here.
