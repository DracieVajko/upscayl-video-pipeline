# Upscayl Video Pipeline

A local FFmpeg + Upscayl pipeline for upscaling video:

```
video → frames → Upscayl → frames → video (with audio, subtitles, chapters)
```

**Status:** V1 and V2 implemented and validated locally. Split, manual GUI or
automated `upscayl-bin` upscaling, all-in-one `run`, chunked processing, and
assemble work end-to-end in both versions.

## Versions

| | V1 (default) | V2 (optional) |
|---|---|---|
| Location | repository root | `v2/` |
| Requires | Python 3.10+ | PowerShell 5.1+ (Windows), bash 3.2+ (Unix) |
| Avoids | — | Python, Node, `jq` |
| Launcher | `upscayl-video.bat` / `upscayl-video.sh` | `v2/windows/UpscaylVideo.bat` / `bash v2/unix/upscayl-video.sh` |

Both versions use the same commands, flags, `job.txt` contract, presets,
audio/subtitle rules, and exit codes. They share `config.txt` in the repository
root and the same `work/` directory, so on Windows a job created by one version
can be finished by the other.

**Use only one if you want.** V1 does not depend on `v2/`: delete that folder
and the pipeline keeps working. V2 is self-contained code in `v2/`; if you move
it out of the repository, pass `--config` and `--work-dir` so it does not look
for the original root.

## Repository layout

- **`/` — V1**, the Python reference implementation.
- **`v2/` — V2**, the native implementation. Optional; see
  [`v2/README.md`](v2/README.md).
- **`docs/`** — shared usage, validation, troubleshooting, design, and plans.
- **`TEST_EXAMPLE_VIDEOS/`** — local test clips, not committed.

- Design: [`docs/specs/2026-10-26-upscayl-video-pipeline-design.md`](docs/specs/2026-10-26-upscayl-video-pipeline-design.md)
- V1 core plan: [`docs/superpowers/plans/2026-10-26-upscayl-video-pipeline-v1-core.md`](docs/superpowers/plans/2026-10-26-upscayl-video-pipeline-v1-core.md)
- V1 automation plan: [`docs/superpowers/plans/2026-10-26-upscayl-video-pipeline-v1-automation.md`](docs/superpowers/plans/2026-10-26-upscayl-video-pipeline-v1-automation.md)
- V2 parity plan: [`docs/superpowers/plans/2026-10-26-upscayl-video-pipeline-v2-parity.md`](docs/superpowers/plans/2026-10-26-upscayl-video-pipeline-v2-parity.md)
- Usage: [`docs/USAGE.md`](docs/USAGE.md)
- Troubleshooting: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)
- Validation record: [`docs/VALIDATION.md`](docs/VALIDATION.md)
- Mentioning it to Upscayl: [`docs/UPSTREAM.md`](docs/UPSTREAM.md)

## What works now

- One or many input videos, each with its own `work/<job>/` folder; `upscale`
  and `assemble` accept a job folder or the work directory.
- `split-all` + `finish`: `input/` → `work/<job>/batch00001/in|out` → `output/`,
  with extracted audio and an empty `work/` after success.
- Split to PNG or JPEG with optional denoise, HDR tonemapping, CFR conversion,
  resume, `--decode auto` benchmarking, and a sample-based disk estimate.
- `--dry-run` prints the plan and creates no job or frames.
- Manual batch upscaling in the Upscayl GUI, with a menu picker for standard
  and custom models.
- `model-test`: samples frames from a clip, upscales them with every model, and
  writes an HTML comparison report.
- Automated `upscayl-bin` upscaling in bounded, resumable batches, with
  model/ICD/tile discovery and VRAM-based batch sizing.
- All-in-one `run`: split → upscale → assemble, one or many videos, with an ETA
  warning and `--yes` for runs longer than an hour.
- Time-based chunking with `--chunk-seconds auto|N`, resume, `--keep-chunks`,
  and `assemble` finishing a chunked job whose segments still exist.
- MP4 H.264, MP4 HEVC, MKV HEVC, and MOV ProRes.
- NVIDIA NVENC, AMD AMF, or CPU encoding, with automatic fallback.
- Audio copy/AAC/PCM/none, multiple tracks on request, subtitles, chapters.
- `doctor`, `upscale`, `run`, `status`, `clean`, `--dry-run`, and the full
  nine-option menu.
- Windows/NVIDIA Vulkan ICD workaround for the AMD enumeration bug.
- Paths with spaces and Unicode.
- `--max-work-gb` / `--min-free-gb` disk guards and `cleanup=1` in config.
- `--cleanup` publishes the final video to `output/` (configurable with
  `output_dir` / `--output-dir`) and deletes the whole job folder, so `work/`
  ends up empty.
- **V2 parity:** the same commands, flags, contract, presets, audio/subtitle
  rules, exit codes, chunking, resume, doctor, and menu in PowerShell and bash.
  PowerShell also has `split-all` and `finish`; the bash ports and the V2
  `model-test` are a follow-up.

V2 bash has been exercised on Git Bash for Windows and with syntax checks for
bash 3.2, but not on native Linux/macOS. Details in
[`docs/VALIDATION.md`](docs/VALIDATION.md).

## Workspace flow

Put the originals in `input/`, then:

```bash
upscayl-video split-all
# In Upscayl: work\<job>\batch00001\in -> work\<job>\batch00001\out
upscayl-video finish --all
```

`finish` publishes each video to `output/` and removes the job folder, so
`work/` is empty afterwards. `--keep` keeps the work folder.

## Custom models

Upscayl requires the model directory to be named `models`. Put custom `.param`
and `.bin` pairs in such a folder, then point `models_dir` at it, for example:

```ini
models_dir=D:\AI\UpscaylModels\models
```

The menu lists models from the configured directory and from the standard
Upscayl models directory, so custom and built-in models can be mixed. For the
GUI, use the same `models` folder. `doctor` and `upscale` show a clear error if
the configured folder is not named `models`.

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

# Long video: chunked run (auto picks 60 s chunks when disk requires it)
upscayl-video run "movie.mkv" --chunk-seconds auto --preset mkv-hevc --cleanup
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
[`v2/README.md`](v2/README.md) for the native implementation.

## Configuration

Copy `config.example.txt` to `config.txt` in the repository root and set
`ffmpeg`, `ffprobe`, and `work_dir`. CLI flags override the file. Both versions
read this file. Put the work directory on a large drive; 1080p PNG frames are
commonly 1–3 MiB each.

## License

MIT. Upscayl is a separate AGPL-3.0 project; its models are not distributed here.
