# Upscayl Video Pipeline

A local, offline video upscaling pipeline built around **FFmpeg** and
[Upscayl](https://github.com/upscayl/upscayl):

```
video → frames → Upscayl → frames → video (with audio, subtitles, chapters)
```

Everything runs on your machine. No upload, no service, no API key. The pipeline
extracts frames with FFmpeg, upscales them with Upscayl's own CLI, and rebuilds a
video with the original audio, subtitles and chapters.

[![CI](https://github.com/DracieVajko/upscayl-video-pipeline/actions/workflows/ci.yml/badge.svg)](https://github.com/DracieVajko/upscayl-video-pipeline/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Two implementations, one contract

| | **V1 — Python** | **V2 — native** |
|---|---|---|
| Location | repository root | [`v2/`](v2/) |
| Requires | Python 3.10+ | PowerShell 5.1+ (Windows) or bash 3.2+ (Linux/macOS) |
| Avoids | — | Python, Node, `jq` |
| Launcher | `upscayl-video.bat` / `upscayl-video.sh` | `v2/windows/UpscaylVideo.bat` / `bash v2/unix/upscayl-video.sh` |

Both versions implement the same commands, flags, `job.txt` contract, presets,
audio and subtitle rules, and exit codes. They read the same `config.txt` and
work in the same `work/` directory, so on Windows a job started by one version
can be finished by the other.

**Use only one if you prefer.** V1 does not depend on `v2/` — delete that folder
and the pipeline keeps working. V2 is self-contained inside `v2/`; if you copy it
elsewhere, pass `--config` and `--work-dir` so it does not look for the original
repository root.

See [V1 ↔ V2 parity](docs/PARITY.md) for the exact comparison, including the
features that exist in only one implementation.

## Supported operating systems

| | Windows | Linux | macOS |
|---|---|---|---|
| V1 (Python) | yes | yes | yes |
| V2 (native) | yes, PowerShell 5.1+ | yes, bash 3.2+ | yes, bash 3.2+ |

The bash runtime was developed and tested on Windows under Git Bash; native
Linux and macOS runs are covered by a CI syntax check only. The exact state of
every platform is recorded in [docs/VALIDATION.md](docs/VALIDATION.md).

## Requirements

- **V1:** Python 3.10 or newer.
- **V2 Windows:** PowerShell 5.1 or newer. **V2 Unix:** bash 3.2 or newer.
- **FFmpeg and ffprobe** — on the `PATH`, in `config.txt`, or passed with
  `--ffmpeg` / `--ffprobe`.
- **Upscayl** with its `upscayl-bin` CLI and models, for the automated
  `upscale` and `run` commands. Splitting, assembling and the manual GUI
  workflow work without the Upscayl CLI.

## Install

There is no package to install — both versions run from a checkout.

```bash
git clone https://github.com/DracieVajko/upscayl-video-pipeline.git
cd upscayl-video-pipeline
cp config.example.txt config.txt   # optional; config.txt is gitignored
```

Then point `ffmpeg`, `ffprobe`, `upscayl_bin` and `models_dir` at your
installation in `config.txt`, or pass the matching flags on the command line.

## Quick start

```bash
# Windows
upscayl-video.bat doctor --ffmpeg "C:\FFMPEG\ffmpeg.exe" --ffprobe "C:\FFMPEG\ffprobe.exe"

# Linux/macOS
./upscayl-video.sh doctor

# 1. Split the video into frames
upscayl-video split "clip.mp4" --work-dir "D:\UpscaylVideo"

# 2. In the Upscayl GUI:
#      input  D:\UpscaylVideo\clip\frames
#      output D:\UpscaylVideo\clip\upscaled
#    choose a model and a scale, run the batch

# 3. Rebuild the video
upscayl-video assemble "D:\UpscaylVideo\clip" --preset mp4-h264 --encoder auto
```

The same three steps, fully automated with the Upscayl CLI:

```bash
upscayl-video run "clip.mp4" --model upscayl-lite-4x --scale 2 --preset mp4-h264
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

## Workspace flow

Put the originals in `input/`, then:

```bash
upscayl-video split-all
# In Upscayl: work\<job>\batch00001\in -> work\<job>\batch00001\out
upscayl-video finish --all
```

`finish` publishes each video to `output/` and removes the job folder, so
`work/` is empty afterwards. `--keep` keeps the work folder.

## What it does

- One or many input videos, each with its own `work/<job>/` folder.
- Frame extraction as PNG or JPEG, with optional denoise, HDR tonemapping, CFR
  conversion, resume, `--decode auto` benchmarking and a disk estimate.
- Manual upscaling in the Upscayl GUI, or automated `upscayl-bin` upscaling in
  bounded, resumable batches with model, ICD and tile discovery.
- All-in-one `run`: split → upscale → assemble, with an ETA and a confirmation
  prompt for runs longer than an hour.
- Time-based chunking for long videos, with resume and `--keep-chunks`.
- MP4 (H.264), MP4 (HEVC), MKV (HEVC) and MOV (ProRes) output; NVIDIA NVENC,
  AMD AMF or CPU encoding with automatic fallback.
- Audio copy/AAC/PCM/none, multiple audio tracks, subtitles and chapters.
- A `doctor` command that checks the whole toolchain, a `status` overview, a
  `clean` command and an interactive menu.
- `--max-work-gb` / `--min-free-gb` disk guards, and `--cleanup` to publish the
  finished video and delete the job folder.

## Documentation

| Guide | Contents |
|---|---|
| [Usage](docs/USAGE.md) | Every command, flag, config key and exit code |
| [Platforms](docs/PLATFORMS.md) | Installing and running on Windows and on Linux/macOS |
| [V2 (native)](v2/README.md) | The PowerShell and bash implementation |
| [Parity](docs/PARITY.md) | V1 ↔ V2 feature comparison and known differences |
| [Validation](docs/VALIDATION.md) | What was tested, where, and what was not |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Common failures and their fixes |
| [Upstream notes](docs/UPSTREAM.md) | Talking about Upscayl without misrepresenting it |
| [Design spec](docs/specs/2026-10-26-upscayl-video-pipeline-design.md) | The original design and its decisions |
| [Changelog](CHANGELOG.md) | Release history |

## Custom models

Upscayl requires the model directory to be named `models`. Put custom `.param`
and `.bin` pairs in such a folder and point `models_dir` at it:

```ini
models_dir=D:\AI\UpscaylModels\models
```

The menu lists the models from the configured directory and from the standard
Upscayl models directory, so custom and built-in models can be mixed.

## Limitations

- The `model-test` comparison report is implemented in V1 only. The V2
  PowerShell runtime writes the manifest skeleton, the V2 bash runtime does not
  implement the command yet.
- Frame interpolation and HDR output are not supported; HDR sources must be
  tonemapped to SDR before upscaling.
- The V2 bash runtime was validated on Git Bash for Windows and with bash 3.2
  syntax checks; native Linux and macOS execution is not yet part of the
  recorded validation.
- `job.txt` stores native paths, so a job is not portable between operating
  systems by design.

## License

MIT. Upscayl is a separate AGPL-3.0 project; its models are not distributed here.

---

## Support this work

If you find this project useful, consider supporting its ongoing development, maintenance, and improvements.

[![Sponsor](https://img.shields.io/badge/Sponsor-GitHub-ea4aaa?logo=github)](https://github.com/sponsors/DracieVajko)
