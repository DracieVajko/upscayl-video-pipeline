# Upscayl Video Pipeline — Design Specification

- **Status:** Approved — 2026-10-26
- **Date:** 2026-10-26
- **Author:** DracieVajko
- **License:** MIT for this project. Upscayl is a separate AGPL-3.0 project; its models are not distributed with this tool.
- **Repository name:** `upscayl-video-pipeline`
- **UI and documentation language:** English

---

## 1. Summary

A local command-line pipeline that turns one or more videos into AI-upscaled videos using Upscayl's `upscayl-bin` and FFmpeg:

1. Extract video frames losslessly.
2. Optionally prepare frames (format, denoise).
3. Upscale frames with Upscayl in bounded batches.
4. Reassemble the frames into a video.
5. Mux the original audio, subtitles, chapters, and metadata back in.

The project has two independent implementations with the same commands, options, folder layout, and `job.txt` contract:

- **V1:** Python 3.10+ (standard library only), launchers for Windows and Unix.
- **V2:** no Python. PowerShell 5.1+ for Windows, bash 3.2+ for Linux/macOS.

The two versions must be interoperable: a job split by V1 can be upscaled and assembled by V2, and vice versa.

The pipeline must work for short clips and for long videos. It must support a split-only mode for users who prefer to upscale manually in the Upscayl GUI, and a fully automated mode that calls `upscayl-bin` directly.

---

## 2. Problem

Upscayl is an image upscaler. Its GUI and CLI do not process video. A video workflow therefore requires several manual steps:

- split the video into frames;
- keep frame order and timing;
- upscale thousands of images without exhausting memory;
- reconstruct the video at the correct frame rate;
- restore audio, subtitles, chapters, rotation, and color metadata;
- manage very large temporary frame sets;
- recover from interruptions.

The existing public workflows are mostly manual guides or small scripts. They do not provide a complete, resumable, cross-platform pipeline with the required format, audio, subtitle, GPU, and disk-management options.

This project provides that pipeline as a local tool and, later, as a public repository. It does not modify Upscayl itself.

---

## 3. Goals

### 3.1 Functional goals

- Accept one video, several videos, a folder of videos, or drag-and-drop paths.
- Give every source video its own work folder and job metadata.
- Split frames without losing frame order or timing.
- Support PNG and JPEG frame extraction.
- Support optional light/medium/strong denoise before upscaling.
- Upscale with `upscayl-bin`, using installed Upscayl models and a configurable scale (2, 3, or 4).
- Support manual GUI upscaling between split and assemble.
- Assemble the frames at the original or user-specified frame rate.
- Preserve or convert audio: copy, AAC, PCM, or no audio.
- Preserve all audio tracks on request.
- Preserve or convert subtitles: copy, `mov_text`, or none.
- Preserve chapters and global metadata where the container allows it.
- Encode H.264 and H.265 with NVIDIA NVENC, AMD AMF, or CPU (libx264/libx265).
- Encode ProRes 422 HQ for editing.
- Write MP4, MKV, or MOV outputs.
- Handle long videos with time-based chunking, bounded disk use, and resume.
- Provide a `doctor` command that diagnoses missing dependencies, GPU/Vulkan problems, encoder problems, model problems, and disk problems.
- Provide a bilingual-free, English-only CLI and documentation.

### 3.2 Quality goals

- No avoidable generation loss in the frame stage: PNG by default, lossless Upscayl output by default.
- Correct frame count, frame rate, duration, and audio sync.
- No double rotation.
- Correct color tags for SDR output.
- No silent frame skips. If a frame cannot be upscaled, the job fails with a clear error.
- No silent overwrite of source files.
- No deletion outside the job folder.

### 3.3 Usability goals

- Double-click menu for users who do not want to type commands.
- CLI with stable, documented flags for automation.
- Clear progress, ETA, and error messages.
- A single `doctor` command before the first run.
- Documentation that lets another Upscayl user reproduce the workflow.

---

## 4. Non-goals

- A graphical desktop application.
- Parallel processing of multiple jobs on one GPU. Jobs run sequentially by default to avoid VRAM exhaustion.
- Frame interpolation, frame generation, or frame-rate conversion beyond CFR normalization.
- Video restoration beyond AI upscaling (deblocking, denoising is optional; no advanced restoration models).
- HDR output. HDR sources are rejected by default; optional tonemapping produces SDR output.
- 10-bit output by default. Optional 10-bit HEVC is available, but Upscayl's models are 8-bit.
- Audio upscaling, audio restoration, or audio source separation.
- Subtitle editing or translation.
- Downloading models or FFmpeg automatically.
- Bundling FFmpeg, Upscayl, or models.
- Docker, Linux distribution packages, or installers.
- Multiple video tracks. Only the first video stream is processed.
- 3D, VR, or 360-degree special handling.
- Real-time processing.
- Arbitrary scale factors. Upscayl supports 2x, 3x, and 4x; an optional exact target height is achieved by upscaling then downscaling with Lanczos.
- Preserving variable frame rate. Output is CFR.

---

## 5. Evidence and constraints

These facts were verified on the target machine on 2026-10-26. They drive several design decisions.

### 5.1 Installed software

| Item | Value |
|---|---|
| Upscayl | 2.15.0 FOSS, `C:\Program Files\Upscayl` |
| Upscayl CLI | `C:\Program Files\Upscayl\resources\bin\upscayl-bin.exe` |
| Models | `C:\Program Files\Upscayl\resources\models` |
| FFmpeg | 2026-09-24 gyan.dev essentials build |
| FFmpeg path | `C:\FFMPEG\ffmpeg.exe`, `ffprobe.exe` |
| Python | 3.14.7 |
| Git | 2.56.0 |
| GitHub CLI | 2.103.2, authenticated as `DracieVajko` |
| GPU | NVIDIA RTX 3060 Laptop, 6144 MiB; AMD Radeon integrated GPU |
| Free disk | C: 62.7 GB; D: 128.8 GB |

### 5.2 Upscayl CLI behavior

`upscayl-bin.exe` supports:

```
-i input-path        file or directory
-o output-path       file or directory
-z model-scale       2, 3, or 4
-s output-scale      2, 3, or 4
-r resize            WxH
-w width
-c compress          0-100
-t tile-size         >=32, 0 = auto
-m model-path        folder
-n model-name
-g gpu-id
-j load:proc:save
-x tta
-f format            jpg/png/webp
-v verbose
```

Verified behavior:

- When the input is a directory, `upscayl-bin` **preserves the input filename** (for example `frame_00000001.png` → `frame_00000001.png`). The GUI may add a model/scale suffix, so the assembler must also accept suffixed names.
- The output directory must already exist. `upscayl-bin` does not create it.
- `upscayl-bin` has a memory leak in long runs. The GUI and community reports show failures after roughly 1,000–5,000 images. The pipeline must restart the process every batch.
- `upscayl-bin` does not skip existing output files. Resume must be implemented by feeding only missing frames.
- The GUI writes its command line to `%APPDATA%\upscayl\logs\main.log`. The CLI arguments above match the GUI's usage.

### 5.3 Installed models

```
digital-art-4x
high-fidelity-4x
remacri-4x
ultramix-balanced-4x
ultrasharp-4x
upscayl-lite-4x
upscayl-standard-4x
```

Each model has a `.bin` and a `.param` file. Custom models are supported if both files exist.

### 5.4 FFmpeg build constraints

- `libx264`, `libx265`, `h264_nvenc`, `hevc_nvenc`, `h264_amf`, `hevc_amf`, and `prores_ks` are available.
- `-pattern_type glob` is **not** supported by this build. The pipeline must use numbered image sequences (`frame_%08d.png`) or the concat demuxer. It must not depend on glob.
- `-hwaccel cuda` works for decoding.
- `-hwaccel` is optional; CPU decoding was faster for PNG extraction in the benchmark below.
- `-map 0:v:0 -map 1:a?` and stream-specific codec mapping work as expected.

### 5.5 Vulkan / GPU constraint

On this machine, `upscayl-bin` fails with:

```
vkEnumeratePhysicalDevices failed 5
Error: Invalid GPU Device
```

The cause is the old AMD Vulkan driver. The Vulkan loader enumerates both the NVIDIA and AMD ICDs; the AMD ICD breaks enumeration. Forcing the NVIDIA ICD fixes it:

```powershell
$env:VK_ICD_FILENAMES = "C:\WINDOWS\System32\DriverStore\FileRepository\nvacsi.inf_amd64_...\nv-vk64.json"
```

Both the CLI and the GUI reproduced the failure before the workaround. The pipeline must:

- detect NVIDIA;
- find the NVIDIA ICD JSON in the DriverStore;
- set `VK_ICD_FILENAMES` only for the `upscayl-bin` subprocess;
- allow `--icd auto|none|<path>`;
- report the problem and the fix in `doctor`.

The user should still update the AMD driver independently. The tool must not modify drivers or system settings.

### 5.6 Performance benchmark

Synthetic `testsrc2` footage, 1920×1080, 30 fps, 5 s, on the target machine. These numbers are order-of-magnitude guidance, not guarantees.

| Operation | Result |
|---|---|
| Extract 150 PNG frames, CPU decode | 1.44 s |
| Extract 150 PNG frames, CUDA decode | 1.87 s |
| Encode 60 frames 1080p, NVENC H.264 | 2.30 s |
| Encode 60 frames 1080p, NVENC HEVC | 2.09 s |
| Encode 60 frames 1080p, AMF H.264 | 1.97 s |
| Encode 60 frames 1080p, AMF HEVC | 1.97 s |
| Encode 60 frames 1080p, libx264 medium | 1.77 s |
| Encode 60 frames 1080p, libx265 medium | 1.71 s |
| Upscayl standard 4x → 2x, tile auto, 10 frames | 244.75 s (24.48 s/frame) |
| Upscayl standard 4x → 2x, tile 128, 3 frames | 44.74 s (14.91 s/frame) |
| Upscayl standard 4x → 2x, tile 256, 3 frames | 14.88 s (4.96 s/frame) |
| Upscayl standard 4x → 2x, tile 256, 10 frames | 21.59 s (2.16 s/frame, including model load) |
| Upscayl lite 4x → 2x, tile 128, 3 frames | 4.96 s (1.65 s/frame, including model load) |

Conclusions:

- **Tile auto is harmful on this GPU.** Use an explicit tile size derived from VRAM.
- **CPU decode is faster than CUDA for PNG extraction** on this machine. GPU decode remains available and is selected automatically when the per-job benchmark shows it is faster.
- **Upscayl is the bottleneck.** A 1-minute 1080p clip at 30 fps (1,800 frames) can take roughly 30–60 minutes with the standard model and roughly 15–30 minutes with the lite model. Long videos take hours. The tool must show an ETA and a warning before starting.
- **Disk use is large.** The synthetic 1080p PNG frames averaged about 0.31 MB each; real footage is often 1–3 MB per frame. The tool must estimate from a real sample frame, not from a constant.

### 5.7 Prior art

| Project | What it does | Gap relative to this project |
|---|---|---|
| Upscayl Discussion #542, pinned "Upscaling videos guide" | Manual FFmpeg commands plus Upscayl GUI batch | Manual frame handling, no multi-video, no resume, no chunking, no GPU diagnosis, no audio/subtitle matrix |
| `akshaysharma016/upscayl-video` | Bash scripts for frame extraction, `upscayl-bin`, reassembly | Linux-oriented, Real-ESRGAN naming, no Windows GPU fix, no chunking, no full audio/subtitle/container matrix, no V2 no-Python parity |
| `troygeiger/UpscaylVideo` | C# Avalonia GUI orchestrating Upscayl and FFmpeg, batches of 20 due to the memory leak | GUI/.NET dependency, no CLI-first workflow, no V1/V2 split, no detailed preset matrix, no manual-GUI interoperability |

This project does not claim novelty. It aims to be a complete, testable, local-first pipeline with a no-Python implementation and specific fixes for the Windows/NVIDIA/AMD environment above.

---

## 6. Architecture

### 6.1 Components

```
upscayl-video-pipeline/
├── upscayl-video.py              # V1 launcher (adds src/ to sys.path)
├── upscayl-video.bat             # V1 Windows launcher
├── upscayl-video.sh              # V1 Unix launcher
├── src/upscayl_video/            # V1 Python package (stdlib only)
│   ├── __init__.py
│   ├── cli.py                    # argparse, command dispatch
│   ├── config.py                 # config.txt, defaults, validation
│   ├── job.py                    # job folder, job.txt, source.txt, markers
│   ├── probe.py                  # ffprobe JSON, fps rational, streams
│   ├── frames.py                 # extraction, counting, validation, matching
│   ├── upscayl.py                # discovery, ICD, models, batching, smoke test
│   ├── encode.py                 # presets, encoder selection, audio/subs, concat
│   ├── disk.py                   # sample estimates, free space, chunk decision
│   ├── pipeline.py               # orchestration, chunking, resume, cleanup
│   ├── doctor.py                 # environment checks
│   ├── menu.py                   # interactive menu
│   └── util.py                   # logging, subprocess, paths, errors
├── v2/
│   ├── windows/
│   │   ├── UpscaylVideo.bat      # V2 Windows launcher/menu
│   │   └── UpscaylVideo.ps1      # V2 full implementation
│   └── unix/
│       └── upscayl-video.sh      # V2 full implementation
├── input/                          # optional drop folder for input videos
├── work/                           # default work directory (gitignored)
├── tests/
│   ├── fixtures/
│   └── ...
├── docs/
│   ├── specs/2026-10-26-upscayl-video-pipeline-design.md
│   ├── USAGE.md
│   ├── TROUBLESHOOTING.md
│   └── PERFORMANCE.md
├── config.example.txt
├── README.md
├── LICENSE
├── CHANGELOG.md
└── .gitignore
```

### 6.2 V1 and V2 strategy

- **V1 (Python)** is the reference implementation. It is modular, testable, and easy to extend.
- **V2 (no Python)** is a full-parity implementation:
  - Windows: PowerShell 5.1+ and a `.bat` launcher.
  - Linux/macOS: bash 3.2+.
- V2 is a separate codebase. It must not call Python, Node, `jq`, or any other runtime beyond PowerShell/bash and the required FFmpeg/Upscayl binaries.
- V2 is written as a single, well-sectioned script per platform to keep distribution simple: copy the folder, run the launcher. This is a deliberate trade-off; tests compensate.
- V1 and V2 share the folder layout, `job.txt`, `config.txt`, command names, flags, defaults, and exit codes. The test suite runs cross-version jobs (V1 split → V2 assemble and vice versa).
- V2 may produce simpler console rendering (batch counts instead of a progress bar), but no functional feature may be missing.

### 6.3 Shared contract

The contract is intentionally based on text files, not JSON:

- JSON parsing in bash would require `jq`.
- Batch scripts handle key=value files more reliably than nested JSON.
- The files are human-readable and easy to debug.

Rules:

- `job.txt` and `config.txt` are UTF-8 without BOM. Readers tolerate a BOM and CRLF.
- One `key=value` pair per line. Split on the first `=`. Values may contain `=` and spaces. Values must not contain newlines.
- Lines starting with `#` are comments in `config.txt`. `job.txt` does not use comments.
- Unknown keys are preserved when a file is rewritten.
- Writes are atomic: write a temporary file in the same directory, then replace.
- Paths are stored in native form for the current OS. Jobs are not portable across operating systems.

### 6.4 Data flow

```
input video(s)
   │
   ├─ probe (ffprobe)
   ├─ estimate disk / choose chunking
   ├─ split (ffmpeg) ──► frames/frame_00000001.png ...
   │
   ├─ [optional manual Upscayl GUI]
   │
   ├─ upscale (upscayl-bin, batches) ──► upscaled/frame_00000001.png ...
   │
   ├─ assemble (ffmpeg) ──► output/<name>_upscaled.mp4|mkv|mov
   │       audio, subtitles, chapters, metadata from source
   │
   └─ optional cleanup
```

For chunked `run` jobs, the split/upscale/encode loop runs per chunk, then the video-only chunks are concatenated and the original audio/subtitles are muxed once. `split`, `upscale`, and `assemble` operate on whole jobs; they do not create new chunks.

### 6.5 Design principles

- One job per source video; no shared mutable state between jobs.
- Explicit stages and marker files; every stage can be re-run.
- No silent fallbacks that change quality or container without telling the user.
- Prefer CPU when it is faster; prefer GPU when it is faster; always verify with a smoke test or benchmark.
- Fail safely: keep intermediates on failure, never delete the source, never delete outside the job.
- Print the exact command on `--verbose` so the user can reproduce it.

---

## 7. Work folder and job format

### 7.1 Work folder layout

Default work directory: `<project>/work`, overridable with `--work-dir` or `config.txt:work_dir`.

```
<work-dir>/
└── <job_id>/
    ├── job.txt
    ├── source.txt
    ├── frames/
    │   └── frame_00000001.png ...
    ├── upscaled/
    │   └── frame_00000001.png ...
    ├── chunks/
    │   ├── chunk_0001.ts
    │   ├── chunk_0002.ts
    │   └── concat.ts
    ├── sequence/                # transient normalized hardlinks for manual GUI names
    ├── batch_0001/              # transient; deleted after success
    ├── output/
    │   └── <source_stem>_upscaled.mp4
    ├── logs/
    │   ├── split.log
    │   ├── upscale.log
    │   ├── assemble.log
    │   └── run.log
    ├── .done_split
    ├── .done_upscale
    ├── .done_assemble
    └── .done_chunk_0001 ...
```

- `source.txt` mirrors the `source` key in `job.txt` for quick inspection and simple shell scripts. `job.txt` is authoritative if they disagree.
- `job_id` is the sanitized source stem, truncated to 80 characters.
- If the folder already exists and its `source.txt` points to the same absolute source path, the job is reused.
- If the folder exists but points to a different source, `_2`, `_3`, ... is appended.
- Sanitization: replace characters that are invalid in Windows file names (`<>:"/\|?*`) and control characters with `_`; replace whitespace runs with `_`; collapse repeated `_`; strip leading/trailing dots and spaces. Keep Unicode letters and digits, so Slovak or other non-ASCII stems remain readable. Avoid Windows reserved device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`) by appending `_`. Truncate to 80 characters. If the result is empty, use `video`.
- One job represents one source and one trim range. Two different ranges of the same source collide on the job id; use separate work directories or `--force` to replace the existing job. The tool does not create automatic range variants.

### 7.2 `job.txt`

Required keys:

| Key | Meaning |
|---|---|
| `version` | Contract version, currently `1` |
| `job_id` | Folder name |
| `source` | Absolute source path |
| `source_size` | Source size in bytes |
| `source_mtime` | Source modification time, Unix seconds |
| `created` | ISO-8601 local timestamp |
| `source_duration` | Original source duration in seconds, 3 decimals |
| `duration` | Processed duration in seconds (trim range or source duration), 3 decimals |
| `fps` | Rational frame rate, for example `30000/1001` |
| `fps_decimal` | Decimal frame rate, for example `29.970` |
| `width` | Source width |
| `height` | Source height |
| `pix_fmt` | Source pixel format |
| `frame_format` | `png` or `jpg` |
| `frame_pattern` | For example `frame_%08d.png` |
| `frame_count` | Actual extracted frame count, updated after split |
| `range_start` | Trim start in seconds, `0` if none |
| `range_end` | Trim end in seconds, empty if none |
| `scale` | Upscayl output scale, `2`, `3`, or `4` |
| `target_height` | Optional exact output height, empty if none |
| `model` | Upscayl model name |
| `decode` | `cpu` or `gpu` |
| `denoise` | `none`, `light`, `medium`, `strong` |
| `png_compression` | `0`–`9` |
| `jpeg_quality` | `1`–`31` |
| `chunk_seconds` | `0` or chunk length in seconds |
| `chunk_frames` | Frames per chunk, `0` if no chunking |
| `preset` | Output preset |
| `encoder` | `auto`, `nvidia`, `amd`, `cpu` |
| `audio` | `auto`, `copy`, `aac`, `pcm`, `none` |
| `audio_bitrate` | kbps, for example `192` |
| `all_audio` | `0` or `1` |
| `subs` | `auto`, `copy`, `convert`, `none` |
| `ten_bit` | `0` or `1` |
| `tonemap` | `0` or `1` |
| `color_primaries` | Output color primaries (`bt709`, `bt601`, ...) or `unknown` |
| `color_trc` | Output transfer function (`bt709`, ...) or `unknown` |
| `colorspace` | Output color matrix (`bt709`, `bt601`, ...) or `unknown` |
| `color_range` | Output color range (`tv`, `pc`) or `unknown` |
| `hdr` | `0` or `1` |
| `upscaled_count` | Optional, updated after upscale |
| `last_error` | Optional, short error text |
| `updated` | Optional, ISO-8601 timestamp |

Rules:

- `source` and `range_end` values may contain spaces and `=`.
- `duration`, `fps`, and counts are written by the tool, not guessed by the user.
- If the source file size or mtime changes, the job is stale. The tool warns and requires `--force` to continue.
- Changing `frame_format`, `fps`, `range_start`, `range_end`, `denoise`, `tonemap`, `png_compression`, or `jpeg_quality` after split requires `--force` and a fresh split. `tonemap` changes the extracted pixels, so it belongs to the split stage, not the assemble stage.
- Changing `model` or `scale` after upscale requires `--force` and a fresh upscale. The frames are kept; `upscaled/` and `.done_upscale` are cleared after confirmation.
- Changing `preset`, `encoder`, `audio`, `subs`, `ten_bit`, or `target_height` after assemble only requires a new assemble (`--force` if the output exists).
- When `tonemap=1`, the `color_*` fields describe the SDR output (`bt709`/`tv`), not the HDR source.

### 7.3 `config.txt`

Default location: next to the tool. Overridable with `--config`.

```ini
# Upscayl Video Pipeline configuration
ffmpeg=ffmpeg
ffprobe=ffprobe
upscayl_bin=auto
models_dir=auto
work_dir=work
default_model=upscayl-standard-4x
default_scale=2
default_preset=mp4-h264
default_encoder=auto
default_audio=auto
default_subs=auto
tile=auto
batch_size=100
gpu=0
icd=auto
max_work_gb=40
min_free_gb=5
cleanup=0
```

- `auto` means "discover" for paths and ICD, and "derive" for tile.
- CLI flags override `config.txt`.
- Job-specific values in `job.txt` override defaults for that job.
- Paths may contain spaces; do not quote them in `config.txt`. Leading and trailing whitespace is trimmed.
- Relative paths in `config.txt` are resolved relative to the directory containing the config file. The default `work_dir=work` therefore means `<tool>/work`.
- Relative paths passed on the command line (`--work-dir`, `--output`, `--config`) are resolved relative to the current working directory.
- `cleanup=1` is equivalent to `--cleanup` for `run`.

### 7.4 Marker files

- `.done_split`: frames are complete and contiguous.
- `.done_upscale`: all frames have a corresponding upscaled output.
- `.done_assemble`: final output exists and passed `ffprobe` validation.
- `.done_chunk_NNNN`: chunk `NNNN` has a valid video-only segment.

Markers are empty files. They are written only after validation. Deleting a marker forces the stage to re-run.

### 7.5 Job selection

- `split` and `run` take video paths.
- `upscale` and `assemble` take job folders (a folder containing `job.txt`) or `--all` (all jobs).
- `clean` takes job folders or `--all-jobs`; its target selection uses `--frames`, `--upscaled`, `--chunks`, `--batch`, or `--all-intermediates`.
- If `--all` is used, jobs are processed in sorted job-id order.
- A job folder can be passed by absolute or relative path.
- `status` scans the work directory; it does not require a job argument.

---

## 8. Commands and UX

### 8.1 Command set

```
upscayl-video doctor
upscayl-video split   <video...> [options]
upscayl-video upscale <job...>  [options]
upscayl-video assemble <job...> [options]
upscayl-video run     <video...> [options]
upscayl-video status  [options]
upscayl-video clean   <job...>  [options]
```

V2 uses the same command names:

```
UpscaylVideo.bat doctor
UpscaylVideo.bat run "video.mp4" --preset mp4-hevc
.\upscayl-video.sh doctor
./upscayl-video.sh run "video.mp4" --preset mp4-hevc
```

### 8.2 Global options

| Option | Meaning |
|---|---|
| `--work-dir <dir>` | Work directory; default from config |
| `--config <file>` | Config file; default `config.txt` next to the tool |
| `--ffmpeg PATH` | FFmpeg executable; overrides config and discovery |
| `--ffprobe PATH` | ffprobe executable; overrides config and discovery |
| `--verbose` | Print commands and debug information |
| `--quiet` | Print errors only; logs still written |
| `--yes` | Do not ask for confirmation |
| `--force` | Overwrite outputs and clear incompatible stages |
| `--allow-huge` | Allow outputs larger than 8192 px on a side or 40 megapixels |
| `--dry-run` | Print what would happen; create nothing |
| `--version` | Print version and exit |
| `--help` | Print help and exit |

### 8.3 `split`

```
upscayl-video split <video...> [--fps N] [--start HH:MM:SS] [--end HH:MM:SS]
  [--format png|jpg] [--jpeg-quality 1-31] [--png-compression 0-9]
  [--denoise none|light|medium|strong] [--tonemap] [--decode cpu|gpu|auto]
  [--scale 2|3|4] [--target-height N] [--model NAME]
  [--work-dir DIR] [--recursive] [--verify-frames]
```

Behavior:

1. Resolve inputs.
2. Probe each source.
3. Create or reuse the job.
4. Validate settings against an existing job.
5. Estimate disk use.
6. Warn if the estimate is high, but proceed. Chunking is orchestrated by `run`, not by `split`.
7. Extract frames.
8. Count and validate frames.
9. Write `.done_split`.

Time values for `--start`/`--end` accept `SS`, `MM:SS`, or `HH:MM:SS`, with optional fractional seconds. `--fps` accepts a decimal (`29.97`) or a rational (`30000/1001`).

Split does not upscale or encode. It always extracts the full selected range. For long videos that would exceed the disk budget, use `run --chunk-seconds` instead of split-only.

`split --model` and `split --scale` are recorded in `job.txt` for the later upscale; they are validated by `upscale`, not by `split`. `--target-height` does affect the chosen `scale` immediately.

Target height rule:

- If `--target-height N` is set and `--scale` is **not** set, choose the smallest scale in `{2, 3, 4}` such that `height × scale >= N`.
- If `N <= height`, exit 4: the target must be larger than the source height. Upscaling to the same or a smaller height is not a supported use case.
- If both are set, use the explicit scale. If `height × scale < N`, exit 4; the tool does not upscale beyond 4x.
- If `height × scale > N`, the assembler downscales to exactly `N` with Lanczos, preserving aspect ratio and even dimensions.
- If `N` is odd, round it up to the nearest even number and warn.
- The final output must satisfy the size guard in section 9.11 unless `--allow-huge` is set.

### 8.4 `upscale`

```
upscayl-video upscale <job...> [--model NAME] [--scale 2|3|4]
  [--gpu N] [--tile auto|N]
  [--batch-size N] [--threads L:P:S] [--icd auto|none|PATH]
  [--upscayl-bin PATH] [--models-dir DIR] [--retry N]
  [--upscaled-dir DIR]
```

Behavior:

1. Discover `upscayl-bin` and models.
2. Validate the model and scale.
3. Set the ICD if needed.
4. Scan `upscaled/` for existing valid outputs.
5. Process missing frames in batches.
6. Restart `upscayl-bin` for every batch.
7. Validate output count and file sizes.
8. Write `.done_upscale`.

`--upscaled-dir` is for manual GUI output. If set, the assembler and the resume scanner read from that directory instead of `upscaled/`.

### 8.5 `assemble`

```
upscayl-video assemble <job...> [--preset mp4-h264|mp4-hevc|mkv-hevc|mov-prores]
  [--encoder auto|nvidia|amd|cpu] [--quality fast|balanced|quality]
  [--crf N] [--audio auto|copy|aac|pcm|none] [--audio-bitrate N]
  [--all-audio] [--subs auto|copy|convert|none] [--10bit]
  [--target-height N] [--cleanup] [--keep-chunks] [--output PATH]
  [--upscaled-dir DIR] [--pick newest|largest]
  [--verify-frames] [--allow-huge]
```

Behavior:

1. Validate the job and frames.
2. Choose the upscaled frame set: `upscaled/` by default, or `--upscaled-dir DIR` for manual GUI output in a custom location. Normalize non-standard names through a temporary `sequence/` directory when needed.
3. Choose the encoder and test it if needed.
4. Build the FFmpeg command.
5. If the job already has chunk segments from an interrupted chunked `run`, concatenate them. Otherwise encode the whole frame set in one pass. `assemble` does not re-extract or re-upscale frames, so `--chunk-seconds` is a `run` option, not an `assemble` option.
6. Mux audio, subtitles, chapters, and metadata.
7. Validate the output with `ffprobe`.
8. Write `.done_assemble`.
9. Optionally clean intermediates.

`--tonemap` is intentionally **not** an assemble option: tonemapping happens during split, before the frames reach Upscayl. If a job was split without tonemapping, `assemble` refuses `--tonemap` and tells the user to re-split with it.

Output path rules:

- Without `--output`, the default is `output/<source_stem>_upscaled.<ext>`. If it exists and `--force` is not set, append `_1`, `_2`, ... rather than overwrite.
- With `--output FILE`, an existing file is an error unless `--force` is set. The tool does not silently append a suffix to an explicit path.
- With `--output DIR`, the default filename is used inside that directory, with the same collision rule as the default output.
- `--output FILE` is valid only for a single input/job. With multiple inputs/jobs, use `--output DIR` or omit the option.
- The output extension is chosen by the preset: `.mp4`, `.mkv`, or `.mov`.

### 8.6 `run`

```
upscayl-video run <video...> [all split/upscale/assemble options]
  [--chunk-seconds auto|0|N] [--stop-on-error] [--recursive]
  [--output PATH] [--cleanup]
```

Behavior:

- For each input: split → upscale → assemble.
- Reuses existing stages and markers.
- Continues to the next video after a failure by default; `--stop-on-error` stops.
- Prints a final summary table.
- With `--cleanup`, deletes `frames/`, `upscaled/`, `chunks/`, `sequence/`, and `batch_*` after a successful assemble.
- `--tonemap` is passed to split; it is rejected by assemble if the job's frames were not tonemapped.

### 8.7 `status`

```
upscayl-video status [--work-dir DIR] [--verbose]
```

Prints one row per job:

```
JOB                     STAGE       FRAMES  UPSCALED  OUTPUT
myvideo                 done        1800    1800      myvideo_upscaled.mp4 (1.2 GB)
otherclip               upscale      900     420       -
```

`STAGE` is derived from markers and counts: `split`, `upscale`, `assemble`, `done`, `failed`, `empty`.

For chunked jobs, `FRAMES` and `UPSCALED` are taken from `job.txt` and chunk markers, not from the current contents of `frames/`/`upscaled/`, because chunk intermediates are deleted after each chunk. `--verbose` shows the completed chunk count.

### 8.8 `clean`

```
upscayl-video clean <job...> [--frames] [--upscaled] [--chunks] [--batch]
  [--all-intermediates] [--include-output] [--all-jobs] [--dry-run]
```

Behavior:

- Deletes only the selected directories inside a valid job folder.
- `--all-intermediates` selects `frames`, `upscaled`, `chunks`, `sequence`, and `batch_*`.
- `--include-output` additionally deletes `output/`; it requires an explicit flag.
- `--all-jobs` applies the selection to every job in the work directory; otherwise at least one job path is required.
- Never deletes the source video.
- Refuses to operate on a folder that is not a valid job or is outside the work directory.
- Naming note: `upscale` and `assemble` use `--all` for "all jobs"; `clean` uses the explicit `--all-jobs` and `--all-intermediates` to avoid ambiguity.

### 8.9 `doctor`

```
upscayl-video doctor [--work-dir DIR] [--model NAME] [--tile auto|N]
  [--skip-upscayl-smoke] [--verbose]
```

Checks:

1. FFmpeg and ffprobe exist, run, and report versions.
2. Encoders:
   - required: `libx264` (the universal fallback and `mp4-h264` default);
   - preset-specific: `libx265` (`mp4-hevc`, `mkv-hevc`), `prores_ks` (`mov-prores`);
   - optional: `h264_nvenc`, `hevc_nvenc`, `h264_amf`, `hevc_amf`.
   Missing preset-specific or optional encoders are warnings; selecting a preset/encoder that needs one fails at runtime with a clear message.
3. A 1-frame encode smoke test for each available encoder.
4. `upscayl-bin` exists and is executable.
5. Models directory exists and contains at least one `.bin`/`.param` pair.
6. GPU detection: NVIDIA via `nvidia-smi`, AMD via WMI/`/sys`, Vulkan ICD discovery.
7. Upscayl smoke test: generate a 64×64 PNG, upscale it with the selected model and tile, verify the output, delete the temp files. If the test fails and an NVIDIA ICD exists but is not configured, retry once with that ICD and report the result; this is how the AMD Vulkan enumeration bug is diagnosed.
8. Free space and write permission on the work directory.
9. Python version (V1) or PowerShell/bash version (V2).
10. FFmpeg glob support: report only; the pipeline does not require it.

Exit behavior:

- Exit 0 if the required checks pass: FFmpeg and ffprobe are usable, `libx264` is available, and the work directory is writable.
- Missing Upscayl, missing models, or missing GPU encoders are **warnings**, not fatal: `split` and `assemble` can still work. `upscale` and `run` will exit 3 later if Upscayl is actually needed.
- If Upscayl exists but the smoke test fails, exit 6.
- If the work drive has less than `min_free_gb`, exit 5.
- `--skip-upscayl-smoke` turns the smoke test into a warning.

### 8.10 Interactive menu

When invoked with no arguments and a TTY, both versions show:

```
Upscayl Video Pipeline
1) Run all (split + upscale + assemble)
2) Split only
3) Upscale only
4) Assemble only
5) Status
6) Doctor
7) Clean
8) Settings
9) Exit
```

Prompts:

- Input file, folder, or job.
- Model (numbered list of installed models, with a short recommendation).
- Scale (2/3/4).
- Preset (mp4-h264, mp4-hevc, mkv-hevc, mov-prores).
- Audio (auto/copy/aac/none/all).
- Subtitles (auto/copy/convert/none).
- Cleanup after success (y/N, default N).
- If an HDR source is detected, explain that Upscayl is 8-bit SDR and ask whether to tonemap to SDR (default N; declining aborts that input).
- Confirmation summary before starting.

Defaults come from `config.txt` and are shown in brackets. The menu is English. Ctrl+C exits cleanly with code 130.

When invoked with no arguments and no TTY, print help and exit 2.

### 8.11 Examples

```bash
# Diagnose the environment once
upscayl-video doctor

# One video, 2x, general model, MP4 H.264, automatic audio/subtitles
upscayl-video run "C:\Videos\clip.mp4" --preset mp4-h264 --scale 2

# Several videos, work folder on D:, HEVC, lite model, cleanup
upscayl-video run "C:\Videos\a.mp4" "C:\Videos\b.mkv" \
  --work-dir "D:\UpscaylVideo" --preset mp4-hevc \
  --model upscayl-lite-4x --cleanup

# Split only, then upscale manually in the Upscayl GUI
upscayl-video split "C:\Videos\clip.mp4" --format png
# In Upscayl: input work\clip\frames, output work\clip\upscaled
upscayl-video assemble work\clip --preset mkv-hevc --audio copy --subs copy

# Target 2160p from a 720p source (3x) or 1080p source (2x)
upscayl-video run "clip.mp4" --target-height 2160

# Chunk a long video into 60-second pieces and delete chunk frames
upscayl-video run "movie.mkv" --chunk-seconds 60 --preset mkv-hevc --cleanup

# Re-encode manually with AMD AMF
upscayl-video assemble work\clip --preset mp4-hevc --encoder amd --quality quality

# Inspect jobs
upscayl-video status --work-dir "D:\UpscaylVideo"

# Delete intermediates but keep the output
upscayl-video clean work\clip --all-intermediates
```

---

## 9. Pipeline details

### 9.1 Input resolution

- Positional inputs may be files, directories, or wildcard patterns.
- If a directory is passed, scan its top level for:
  `.mp4 .mkv .mov .avi .webm .m4v .ts .m2ts .wmv .flv .mpg .mpeg .ogv`.
- `--recursive` scans subdirectories.
- If no input is given to `run` or `split`, scan `<project>/input`.
- Skip hidden files, files starting with `.`, and files ending in `_upscaled.<ext>`.
- Skip anything under the configured work directory, so `--recursive` never picks up chunk segments or previous outputs. Outputs live inside each job's `output/` by default; `--output DIR` can place them elsewhere.
- Deduplicate by absolute path; sort by name.
- Case-insensitive extensions.

### 9.2 Probing

Use `ffprobe -v error -print_format json -show_format -show_streams`.

Extract:

- duration: prefer the video stream duration. If it is absent (common in
  Matroska), probe the last video packet and use `pts_time + duration_time`.
  Fall back to the format duration only if the tail probe fails. Format
  duration can include a longer audio track and must not drive the frame count;
- `avg_frame_rate` if valid and non-zero, else `r_frame_rate`, else `30/1`;
- width, height, pix_fmt;
- first video stream index;
- audio streams: index, codec_name, channels, bit_rate, language, title;
- subtitle streams: index, codec_name, language, title;
- chapters;
- `color_primaries`, `color_transfer`, `color_space`, `color_range`;
- rotation from side data or `rotate` tag;
- `nb_frames` / `nb_read_packets` from `-count_packets` if present; this is
  metadata/sanity information, not the expected CFR frame count.

Normalize the frame rate to a rational. Store both `fps` and `fps_decimal`.

Validation errors:

- no video stream → exit 4;
- duration ≤ 0 → exit 4;
- width/height ≤ 0 → exit 4;
- FPS invalid → fall back to 30 and warn;
- source missing → exit 4.

### 9.3 Frame extraction

Base command:

```text
ffmpeg -hide_banner -nostdin -y -benchmark
  [-ss <start>] -i <source> [-t <duration>]
  -map 0:v:0 -an -sn -dn
  -fps_mode cfr -r <fps>
  -start_number <first>
  [-vf <tonemap, denoise, pad, format>]
  -compression_level <n> | -q:v <n>
  <frames>/<frame_pattern>
```

Details:

- **Frame numbering:** 8 digits, starting at 1: `frame_00000001.png`. This supports up to 99,999,999 frames.
- **Expected frame count:** `round(processed_duration × fps)`. This is correct
  for CFR output, `--fps` resampling, and VFR sources. The source packet count
  is not used as the expected output count.
- **CFR:** `-fps_mode cfr -r <fps>`. VFR sources are converted to CFR; duplicated/dropped frames are FFmpeg's standard conversion.
- **Range:** `--start` and `--end` use `-ss` before `-i` and `-t` for duration. Modern FFmpeg decodes from the preceding keyframe and discards frames, so the result is frame-accurate without O(n²) seeking.
- **Audio is not extracted.** The original source is used as the audio/subtitle input during assemble. This preserves timing and avoids an extra file.
- **Rotation:** extraction uses FFmpeg's default autorotation, so frames are upright. The assemble stage strips rotation metadata to avoid double rotation.
- **Odd dimensions:** if width or height is odd, add `pad=ceil(iw/2)*2:ceil(ih/2)*2` to the filter chain. This adds at most one pixel and prevents encoder failures.
- **Denoise:** optional `hqdn3d`:
  - light: `hqdn3d=1.5:1.5:6:6`
  - medium: `hqdn3d=2:2:8:8`
  - strong: `hqdn3d=3:3:10:10`
  Denoise is applied before frame output. No sharpening is applied before upscaling.
- **Tonemap:** `--tonemap` is a split-stage option. For HDR sources, it converts to SDR BT.709 **before** the frames reach Upscayl. The filter chain is applied in this order: tonemap → denoise → pad → format.
  - Tonemap chain: `zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p`. The final `format=rgb24` (PNG) or `format=yuvj420p` (JPEG) conversion happens after denoise and pad.
  - `--tonemap` and `--10bit` are mutually exclusive; combining them exits 4.
  - After tonemapping, the job's `color_*` fields are set to `bt709`/`bt709`/`bt709`/`tv` and `hdr=0`.
- **HDR policy:** PQ (`smpte2084`) and HLG (`arib-std-b67`) sources are rejected with exit 4 unless `--tonemap` is set. The tool prints the source transfer function and explains that Upscayl models are 8-bit SDR.
- **10-bit SDR policy:** 10-bit SDR sources are accepted, but the frames are converted to 8-bit RGB for Upscayl. The tool warns about the precision loss. `--10bit` affects only the final HEVC encode; it cannot recover the lost bits.
- **PNG:** `-compression_level 3` by default; configurable 0–9. The filter chain ends with `format=rgb24`, so 10-bit sources produce 8-bit RGB PNGs that Upscayl can read.
- **JPEG:** `-q:v 1` by default (FFmpeg's best JPEG quality); configurable 1–31. The filter chain ends with `format=yuvj420p`. JPEG introduces generation loss; the tool warns once per job.
- **Decode:** `cpu`, `gpu`, or `auto`. In `auto`, run a 30-frame benchmark with `-benchmark` for CPU and GPU, parse `rtime`, and choose the faster. If GPU fails, use CPU. Store the result in `job.txt`.
  - NVIDIA: `-hwaccel cuda`
  - Windows AMD/Intel: `-hwaccel d3d11va`
  - Linux: `-hwaccel vaapi` if `/dev/dri/renderD128` exists
  - macOS: `-hwaccel videotoolbox`
- **Resume:** count contiguous valid frames from index 1. If a partial extraction exists, resume at `last + 1` with `-ss <last/fps> -start_number <last+1>`. Validate settings against `job.txt` first.
- **Atomicity:** a frame is considered valid only if it exists and has size > 0. `--verify-frames` additionally checks the PNG/JPEG signature.
- **Failure:** if FFmpeg exits nonzero, keep the partial frames, write `last_error`, and exit 7. The next run resumes.

### 9.4 Disk estimation

Before split:

1. Extract one sample frame at 10% of the duration (or at 1 second) to a temporary file, using the same format and filters.
2. Measure its size.
3. Estimate:
   - `frames_bytes = sample_bytes × estimated_frames × 1.15`
   - `upscaled_bytes = sample_bytes × scale² × estimated_frames × 1.15`
   - `total = frames_bytes + upscaled_bytes + 1 GiB`
4. Compare with free space on the work drive.
5. Print a table:

```
Source duration: 00:05:00
Frame rate:      30/1 (30.000)
Estimated frames: 9000
Sample PNG:      1.8 MiB
Frames:          18.6 GiB
Upscaled (2x):   74.4 GiB
Total estimate:  94.0 GiB
Free on D::      128.8 GiB
Chunking:        enabled, 60 s per chunk
```

Rules:

- `--max-work-gb` (default 40) caps the estimated total for a single job. In `run`, exceeding it enables chunking automatically.
- `--min-free-gb` (default 5) is a hard floor. In `run`, chunking is used to stay above it; if even chunking cannot, abort with exit 5. In `split`, abort with exit 5 and suggest `run --chunk-seconds` or a different work drive.
- `--chunk-seconds` is a `run` option. `split` does not accept it; it always extracts the whole selected range.
- `--chunk-seconds 0` disables chunking in `run`. The tool still warns if the estimate exceeds the cap.
- JPEG frames use the sample JPEG size; upscaled outputs are PNG by default, so the upscaled estimate uses the PNG sample size when available. If only a JPEG sample exists, multiply by 1.5 to be conservative.
- Estimates are approximate. The tool prints that fact and checks free space before every upscale batch and before every chunk.

### 9.5 Dependency discovery

#### FFmpeg and ffprobe

Search order:

1. `--ffmpeg` / `--ffprobe`.
2. `config.txt:ffmpeg` / `config.txt:ffprobe`.
3. `PATH`.
4. The tool directory.
5. The parent of the tool directory (this covers `C:\FFMPEG\upscayl-video-pipeline` using `C:\FFMPEG\ffmpeg.exe`).
6. Common install locations: `C:\ffmpeg\bin`, `/usr/bin`, `/usr/local/bin`, `/opt/homebrew/bin`.

If a configured path is a directory, look for `ffmpeg.exe`/`ffprobe.exe` (Windows) or `ffmpeg`/`ffprobe` (Unix) inside it. If nothing is found, exit 3 with the searched locations.

#### `upscayl-bin`

Search order for `upscayl-bin`:

**Windows**

1. `--upscayl-bin`
2. `config.txt:upscayl_bin`
3. `UPSCAYL_BIN` environment variable
4. `%ProgramFiles%\Upscayl\resources\bin\upscayl-bin.exe`
5. `%LOCALAPPDATA%\Programs\Upscayl\resources\bin\upscayl-bin.exe`
6. `upscayl-bin.exe` in `PATH`

**Linux**

1. `--upscayl-bin`
2. `config.txt:upscayl_bin`
3. `UPSCAYL_BIN`
4. `upscayl-bin` in `PATH`
5. `/opt/upscayl/resources/bin/upscayl-bin`
6. `/opt/Upscayl/resources/bin/upscayl-bin`
7. AppImage mount paths under `/tmp/.mount_*` (search for `resources/bin/upscayl-bin`)

**macOS**

1. `--upscayl-bin`
2. `config.txt:upscayl_bin`
3. `UPSCAYL_BIN`
4. `upscayl-bin` in `PATH`
5. `/Applications/Upscayl.app/Contents/Resources/bin/upscayl-bin`

Models directory:

- CLI `--models-dir`, config, `UPSCAYL_MODELS`, then `../models` relative to the CLI, then the standard install paths.

If the CLI or models are missing:

- `split` and `assemble` still work.
- `upscale` and `run` exit 3 with installation guidance.

Execution environment:

- Run `upscayl-bin` with its own directory as the working directory (or add that directory to `PATH`) so bundled DLLs such as `vulkan-1.dll` resolve on Windows.
- Pass absolute paths for input, output, models, and ICD so the working-directory change does not affect them.
- On macOS, preserve the app bundle's library path if the CLI requires it; document any `DYLD_*` override in `TROUBLESHOOTING.md`.

### 9.6 GPU and ICD selection

- Detect NVIDIA with `nvidia-smi` (preferred; also check `%ProgramFiles%\NVIDIA Corporation\NVSMI\nvidia-smi.exe`) or WMI.
- On Windows, find the NVIDIA Vulkan ICD JSON:
  `C:\Windows\System32\DriverStore\FileRepository\nv*\nv-vk64.json`.
  Cache the first valid path in `config.txt` or a small cache file.
- If `--icd auto` (default) and NVIDIA is present, set `VK_ICD_FILENAMES` for the `upscayl-bin` subprocess only.
- If `--icd none`, do not set it.
- If `--icd <path>`, use that path.
- On Linux/macOS, `auto` does not set an ICD unless a known NVIDIA JSON is found; `--icd` is available.

Why: the AMD Vulkan driver on the target machine breaks `vkEnumeratePhysicalDevices`; forcing the NVIDIA ICD fixes it. This is documented in `TROUBLESHOOTING.md`.

### 9.7 Tile and batch sizing

Tile size:

| VRAM | Default tile |
|---|---|
| ≤ 4 GiB | 128 |
| 4–8 GiB | 256 |
| > 8 GiB | 512 |
| Unknown | 256 |

- `--tile auto` uses the table.
- `--tile 0` passes Upscayl's auto mode (not recommended; it was 10× slower on the target machine).
- If an upscale batch fails with a GPU memory error, retry once with the tile halved (minimum 64) and the batch size halved (minimum 1). Log the retry.
- If it still fails, stop and keep the batch directory for debugging.

Batch size:

- Default 100 frames.
- For frames larger than 8 MP, default 50.
- `--batch-size` overrides.
- Restart `upscayl-bin` for every batch. This is mandatory because of the memory leak.

Threads:

- Default `-j 1:2:2`.
- `--threads load:proc:save` overrides.
- The tool does not enable TTA (`-x`) by default; `--tta` is not part of the initial scope because it multiplies runtime.

Upscale format:

- Default `png` with `-c 0` (lossless).
- Upscayl output is always PNG (`-f png -c 0`) for a lossless intermediate. If the input frames are JPEG, the output is still PNG; the tool warns that the intermediate will be larger. Manual GUI outputs in JPG or WebP are accepted by the assembler.

### 9.8 Upscale batching and resume

For each batch:

1. Determine the missing frame indices by scanning `upscaled/` (or `--upscaled-dir`).
2. Select the first `batch_size` missing indices.
3. Create `batch_NNNN/in/` and `batch_NNNN/out/`.
4. Hardlink the source frames into `in/` with their original names. If hardlinking fails, copy.
5. Run `upscayl-bin` with the job's model, scale, GPU, tile, threads, format, and ICD.
6. Verify that every input has a corresponding output with size > 0. Match by stem, not by exact filename: with `-f png`, a `frame_00000001.jpg` input produces `frame_00000001.png`.
7. Move the outputs into `upscaled/` (or the configured directory).
8. Delete `batch_NNNN/`.
9. Log progress: `processed / total`, frames per second, elapsed, ETA.

Resume:

- If the process is interrupted, the next run rescans `upscaled/` and processes only missing indices.
- If a batch directory exists at startup, inspect its outputs: move valid outputs, delete the batch, and continue.
- If an output exists but has size 0, treat it as missing and overwrite it.

Validation:

- Frame count in `upscaled/` must equal `frame_count`.
- The tool does not ffprobe every upscaled frame (too slow); it checks size and, with `--verify-frames`, the file signature.
- If a frame is corrupt, the encode stage will fail; the tool reports the failing frame index from FFmpeg's error and suggests re-upscaling that range.

### 9.9 Manual Upscayl GUI mode

- `split` leaves `frames/` ready.
- The user selects `frames/` in Upscayl, chooses a model and scale, and sets the output folder to `upscaled/` (or lets Upscayl create a subfolder).
- The GUI may name outputs `frame_00000001_upscayl_4x_upscayl-standard-4x.png`.
- The assembler accepts:
  - `frame_00000001.png`
  - `frame_00000001_*.png`
  - the same patterns with `.jpg`, `.jpeg`, `.webp`
- It searches `upscaled/` and one level of subdirectories.
- If two files map to the same index, the default is an error listing both; `--pick newest` or `--pick largest` resolves it.
- The job's `scale` and `model` fields are informational in manual mode; the assembler trusts the actual image dimensions.
- The README includes a short GUI walkthrough.

### 9.10 Frame validation and matching

- Count files matching `^frame_(\d{8})`.
- Require indices to be contiguous from 1 to N. If not, list the missing indices and exit 4.
- If `frame_count` in `job.txt` is non-zero and differs from N, fail with a
  list of missing/extra frames. Do not silently shrink `frame_count`; a partial
  Upscayl batch must be completed first.
- For manual GUI outputs, group by index; resolve duplicates according to `--pick`.
- Sort by numeric index, never by lexicographic filename alone (8-digit padding makes them equivalent, but numeric parsing is safer).
- All selected frames must share one extension. If they do not, exit 4 and tell the user to re-run Upscayl with one output format.
- If the names are not already exactly `frame_%08d.<ext>`, the assembler creates a temporary `sequence/` directory inside the job and hardlinks (or copies, if hardlinking fails) each selected frame to `frame_00000001.<ext>`, `frame_00000002.<ext>`, and so on. It encodes from `sequence/` and deletes the directory after a successful encode. On failure, `sequence/` is kept for debugging. This makes Upscayl GUI suffixes and one-level subdirectories transparent to FFmpeg.
- If the names are already normalized, the assembler encodes directly from `upscaled/` without creating `sequence/`.
- The assembler accepts a frame set whose dimensions are all the same. It probes the first frame; if later frames differ, FFmpeg fails. Optional `--verify-frames` probes all frames (slow).

### 9.11 Encoding

General command shape:

```text
ffmpeg -hide_banner -nostdin -y -benchmark
  -framerate <fps> -start_number 1 -i <frames>/<pattern>
  [-i <source>]
  -map 0:v:0 [-map 1:<audio_idx> ...] [-map 1:<sub_idx> ...] [-map_chapters 1]
  -c:v <encoder> <quality args>
  [-vf <target-height downscale>] -pix_fmt <pix_fmt>
  [-color_primaries ...] [-color_trc ...] [-colorspace ...] [-color_range ...]
  [-c:a <audio args>] [-c:s <subtitle args>]
  [-metadata:s:v:0 rotate=0] [-map_metadata 1]
  [-movflags +faststart] [-tag:v hvc1]
  [-t <output-duration>]
  <output>
```

Rules:

- `-nostdin` prevents FFmpeg from consuming the terminal.
- `-framerate` and `-start_number` must match the extraction settings.
- `-map 1:<idx>` uses the **absolute** stream index reported by ffprobe (for example `-map 1:1`, not `-map 1:a:1`). This avoids confusing absolute stream indices with type-relative audio/subtitle indices.
- `-map 1:a:0?` is valid shorthand only when exactly the first audio track is selected; otherwise use absolute indices. `-map 1:a?` is used only with `--all-audio`.
- `-map 1:<sub_idx>` maps only the subtitle streams selected by the subtitle policy. Do not use `-map 1:s?` when image subtitles are being dropped; FFmpeg would try to convert them and fail.
- `-map_chapters 1` is added only when the source has chapters.
- Do **not** use `-shortest`. Audio tracks are frequently slightly shorter than the video because of codec padding; `-shortest` would silently drop the last video frames. Instead, when audio or subtitles are present, set an explicit output duration: `-t <job duration>` (or `frame_count / fps` when the job duration is missing). This keeps every video frame and trims only longer audio/subtitle tails. With no audio and no subtitles, omit `-t`; the image sequence ends at the last frame.
- `-map_metadata 1` copies global metadata from the source. Stream metadata is not copied wholesale; rotation is explicitly reset.
- `--tonemap` is not used here. Tonemapping happens during split. The only video filters at assemble time are:
  - optional `target_height` downscale: `scale=-2:<target_height>:flags=lanczos`;
  - full-range to limited-range conversion: `scale=in_range=pc:out_range=tv`.
  If both apply, they are combined into one `-vf` chain.
- Output size guard: reject width or height > 8192 px, or more than 40 megapixels, unless `--allow-huge` is set. The check runs before encoding and after upscaling dimensions are known.
- `--target-height` must not exceed the upscaled frame height. If it does, exit 4 and suggest a larger scale. If it equals the frame height, no downscale is applied.
- `-metadata:s:v:0 rotate=0` prevents double rotation.
- `-movflags +faststart` for MP4/MOV.
- `-tag:v hvc1` for HEVC in MP4/MOV for Apple compatibility.
- `-pix_fmt yuv420p` for 8-bit outputs. `yuv420p10le` for `--10bit` HEVC. `yuv422p10le` for ProRes.
- No `-vsync`; image input is CFR by definition.

Encoder selection:

- `auto`: try `h264_nvenc`/`hevc_nvenc`, then `h264_amf`/`hevc_amf`, then `libx264`/`libx265`. Use the cached smoke-test result; if no cache, run a 1-frame test.
- `nvidia`, `amd`, `cpu`: force the family. If the forced encoder fails, exit 7; do not silently fall back.
- GPU encoder flags:

| Encoder | Flags |
|---|---|
| `h264_nvenc` / `hevc_nvenc` | `-preset <p> -tune hq -rc vbr -cq <q> -b:v 0`; `-multipass fullres -spatial_aq 1 -aq-strength 12` only with `--quality quality` |
| `h264_amf` / `hevc_amf` | `-quality quality -rc cqp -qp_i <q> -qp_p <q>` (tested on this machine) |
| `libx264` | `-preset <p> -crf <q>` |
| `libx265` | `-preset <p> -crf <q>` |
| `prores_ks` | `-profile:v 3 -vendor apl0 -pix_fmt yuv422p10le` |

Quality mapping for `--quality fast|balanced|quality`:

| Codec | fast | balanced | quality |
|---|---|---|---|
| H.264 NVENC CQ | 23 | 20 | 18 |
| H.264 AMF QP | 23 | 20 | 18 |
| H.264 x264 CRF / preset | 22 / veryfast | 20 / medium | 18 / slow |
| HEVC NVENC CQ | 25 | 22 | 20 |
| HEVC AMF QP | 25 | 22 | 20 |
| HEVC x265 CRF / preset | 24 / fast | 22 / medium | 20 / slow |
| ProRes profile | 1 (LT) | 2 (422) | 3 (422 HQ) |

- NVENC preset: `p5` for fast, `p6` for balanced, `p7` for quality.
- AMF uses `-quality quality` for all three levels; only the QP values change. This is deliberate because the AMF quality enum is driver/version-dependent; the QP remains the predictable control.
- `--crf N` overrides the numeric quality value and maps to CQ/QP/CRF as appropriate.
- `--quality` and `--crf` are mutually exclusive.
- The default is `--quality balanced`.

Output validation:

- After encoding, run `ffprobe` on the output.
- Require exactly one video stream.
- Width and height must match the expected values after `--target-height`.
- Duration must be greater than 0 and within `max(0.1 s, 1/fps)` of `job.txt:duration`.
- Frame rate must match `job.txt:fps` within rounding.
- If audio was requested and the source had audio, an audio stream must be present.
- If subtitles were selected, the subtitle stream count must match the selection.
- Pixel format must match the preset (`yuv420p`, `yuv420p10le`, or `yuv422p10le`).
- On failure, exit 8, keep all intermediates, and log the ffprobe output.

Output safety:

- The output path must not resolve to the source video. Explicit output paths
  must use the preset's extension (`.mp4`, `.mkv`, or `.mov`).
- Encode to a temporary `*.partial.<ext>` file, validate it, then atomically
  replace the final output. On failure, delete the partial file; an existing
  good output from a previous run must survive.
- Clear `.done_assemble` before starting a re-encode. A failed attempt must not
  leave a stale success marker.
- When audio or subtitles are present, use an explicit `-t <job duration>` as
  described above. Do not use `-shortest`.

### 9.12 Audio

- Default: first audio track, `--audio auto`.
- `auto`:
  - If there is no audio, produce a video-only output.
  - If the container supports the source codec, copy.
  - Otherwise encode to AAC at `--audio-bitrate` (default 192k).
  - For `mov-prores`, default to PCM `pcm_s24le`.
- `copy`: force copy. If FFmpeg fails, exit 7 with a message suggesting `--audio aac` or `--preset mkv-hevc`.
- `aac`: encode all selected tracks to AAC at the configured bitrate.
- `pcm`: encode to `pcm_s24le` for MOV/MKV; error for MP4 (PCM in MP4 is not broadly compatible).
- `none`: no audio; add `-an`.
- `--all-audio`: map all audio tracks. Per-track decision in `auto`: copy compatible tracks, encode incompatible tracks to AAC. Log the decision per track.
- Container compatibility whitelist:
  - MP4: `aac`, `mp3`, `ac3`, `eac3`, `alac`.
  - MKV: any codec.
  - MOV: `aac`, `mp3`, `ac3`, `eac3`, `alac`, `pcm_*`.
- Trimming (`--start`/`--end`):
  - Video is frame-accurate.
  - For sample-accurate audio boundaries, use AAC re-encoding when a trim is active. If the user requested `copy`, the tool warns and uses AAC for the trimmed audio. This avoids packet-boundary offsets.
  - Map audio and subtitles through the same source input, with `-ss
    <range_start>` before `-i <source>` and `-t <duration>` on the output.
  - Chapters are mapped from the source; their timestamps may not shift for a
    trimmed range. The tool warns when chapters are present on a trim.
- Audio bitrate options: 96, 128, 192, 256, 320 kbps. Default 192.
- MP3, AAC, WAV, FLAC, Opus, Vorbis, AC3, EAC3 are supported as inputs.

### 9.13 Subtitles and chapters

- Default: all subtitle tracks, `--subs auto`.
- `auto`:
  - MKV: copy all.
  - MP4/MOV: convert text subtitles (`subrip`, `ass`, `webvtt`, `mov_text`) to `mov_text`. Image subtitles (`hdmv_pgs_subtitle`, `dvd_subtitle`, `dvb_subtitle`, `xsub`) cannot be converted; drop them with a warning that lists the streams and recommends `mkv-hevc`.
- `copy`: copy; error if the container cannot hold the codec.
- `convert`: in MP4/MOV, convert text to `mov_text`; in MKV, convert text to
  `subrip` (Matroska does not support `mov_text`). Error for image subtitles.
- `auto` in MKV: copy compatible text/image codecs and convert `mov_text` to
  `subrip`; `copy` with `mov_text` in MKV is an error.
- `none`: drop subtitles.
- Chapters: `-map_chapters 1` when present.
- Subtitle language and title metadata are preserved by copy; `mov_text` conversion keeps language/title tags where FFmpeg supports them.
- No subtitle burning. This is a non-goal.

### 9.14 Metadata, rotation, color, HDR

Rotation:

- Frames are extracted with autorotation, so they are upright.
- The output video has no rotation matrix. `-metadata:s:v:0 rotate=0` is set defensively.
- Do not use `-noautorotate` for extraction.

Color:

- Probe `color_primaries`, `color_trc`, `colorspace`, `color_range`.
- Pass the tags to the output when known.
- If unknown: use `bt709` for height ≥ 720, `bt601` otherwise; `tv` range.
- If the source is full-range (`pc`), convert to limited range at assemble with `scale=in_range=pc:out_range=tv` and tag `tv`, for broad compatibility. This is combined with the optional target-height downscale.
- PNG frames are RGB; FFmpeg's RGB→YUV conversion uses the filter defaults. The output tags ensure players interpret the result correctly.

HDR and high bit depth:

- HDR is detected when `color_trc` is `smpte2084` (PQ) or `arib-std-b67` (HLG). HDR sources are rejected with exit 4 by default, because Upscayl models are 8-bit SDR and HDR upscaling is not supported.
- `--tonemap` is a **split-stage** option. It converts HDR to SDR BT.709 before the frames reach Upscayl, using:
  `zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p`
  The extraction stage then converts to RGB24 for PNG or YUVJ420P for JPEG. The result is SDR; HDR is permanently lost. The job's `color_*` fields are set to BT.709 and `hdr=0`.
- 10-bit SDR sources are accepted, but they are converted to 8-bit RGB for Upscayl. The tool warns about the precision loss. `--10bit` affects only the final HEVC encode (`yuv420p10le`); it cannot recover the lost bits. `--10bit` is valid only with `mp4-hevc` and `mkv-hevc`; combining it with H.264, ProRes, or `--tonemap` exits 4.
- `--tonemap` and `--10bit` are mutually exclusive; combining them exits 4.
- A 10-bit SDR source does **not** require `--tonemap`; it requires only the 8-bit conversion warning.

### 9.15 Chunking and concatenation

Chunking is required for long videos and for limited disk space. It is orchestrated by `run`; `split`, `upscale`, and `assemble` operate on whole jobs.

Job-state rules:

- A job with chunk markers (`.done_chunk_*` or files in `chunks/`) is a chunked job. `split` and `upscale` refuse it with exit 4 and tell the user to resume with `run`.
- `assemble` is allowed on a chunked job: it concatenates the existing chunk segments and muxes audio/subtitles. This lets the user finish an interrupted `run`.
- If a job already has `.done_split` from a non-chunked split, `run --chunk-seconds N` uses the existing frames and does not re-chunk. To force a chunked re-run, use `--force` (which clears frames after confirmation) or a new work directory.

Decision:

- `--chunk-seconds auto` (default): estimate total disk use; enable chunking if the estimate exceeds `--max-work-gb` or would leave less than `--min-free-gb`.
- `--chunk-seconds 0`: disable.
- `--chunk-seconds N`: force N-second chunks (minimum 10 seconds; if N < 10, use 10 and warn).

Frame accounting:

- `start_frame(i) = round(start_seconds(i) × fps) + 1`
- `end_frame(i) = round(end_seconds(i) × fps)`
- `chunk_frames(i) = end_frame(i) - start_frame(i) + 1`
- The last chunk ends at `round(total_duration × fps)`, where `total_duration` is the processed duration from `job.txt` (`duration`), not `source_duration`.
- This cumulative rounding prevents frame loss or duplication at chunk boundaries.

Per chunk:

1. Extract `chunk_frames` frames starting at `start_frame`, using `-ss start_seconds -t chunk_duration -frames:v chunk_frames`.
2. Upscale the chunk's frames.
3. Encode a **video-only** segment with the final codec settings:
   - H.264/HEVC: MPEG-TS (`.ts`), `-an -sn -dn`.
   - ProRes: MOV (`.mov`), `-an -sn -dn`.
4. Validate the segment with `ffprobe` (duration > 0, video stream present).
5. Write `.done_chunk_NNNN`.
6. Delete the chunk's `frames/` and `upscaled/` unless `--keep-chunks`.

After all chunks:

1. Write a concat list with absolute paths.
2. Concatenate with `-f concat -safe 0 -i list.txt -c copy` into `chunks/concat.ts` (or `.mov`).
3. Mux audio, subtitles, chapters, and metadata from the source:
   `ffmpeg -i chunks/concat.ts -i source -map 0:v:0 -map 1:<audio_idx> -map 1:<sub_idx> ... -c:v copy ...`.
   The indices are absolute ffprobe stream indices. `--all-audio` maps every audio stream.
4. Validate the final output with `ffprobe`.
5. Write `.done_assemble`.
6. Delete chunk segments unless `--keep-chunks`.

Why MPEG-TS for H.264/HEVC: it is tolerant of per-segment extradata and timestamps; `-c copy` concatenation is more reliable than concatenating MP4 fragments produced by different encoder sessions.

Fallbacks:

- If `-c copy` concatenation fails, try MKV as the concat container.
- If it still fails, exit 7 with a message recommending `--chunk-seconds 0` for that video (single encode) or `--preset mkv-hevc`.
- Do not silently re-encode the concatenated video, because that would add another lossy generation.

Audio sync:

- Video-only chunks are concatenated. Their durations sum to the original video duration (within one frame).
- The original audio is muxed once with an explicit `-t <job duration>`, not `-shortest`.
- For trims, the audio range is mapped with `-ss`/`-t`.
- Acceptance test: a 5-second chunked job must have a final duration within 0.1 seconds and an audio stream that starts at 0.

### 9.16 Cleanup

- `run --cleanup`: after a successful assemble, delete `frames/`, `upscaled/`, `chunks/`, `sequence/`, and `batch_*`. Keep `job.txt`, `source.txt`, `logs/`, markers, and `output/`.
- `clean`: explicit selection; `--all-intermediates` selects frames/upscaled/chunks/sequence/batch; `--include-output` adds output.
- Chunk intermediates are deleted after each successful chunk unless `--keep-chunks`.
- On failure, never clean automatically.
- Safety: resolve the job path, verify it is inside the work directory and contains `job.txt`, and refuse to delete symlinks or paths outside the job.

### 9.17 Resume and failure recovery

- Every stage checks its marker and the actual files, not just the marker.
- A marker without valid files is treated as stale and removed with a warning.
- Split resume: contiguous frames only; otherwise require `--force`.
- Upscale resume: missing indices only; batch directories are recovered.
- Assemble resume: if chunks exist, skip completed chunks; if a single encode was interrupted, restart the encode (FFmpeg cannot resume an MP4 encode).
- A source change (size or mtime) invalidates the job; require `--force`.
- GPU failure: retry once with a smaller tile/batch; then fail with logs.
- Encoder failure with `auto`: fall back to the next encoder family; log the fallback. With a forced encoder: fail.
- Disk full: FFmpeg fails; the tool reports the last successful frame and leaves the job resumable. The user can free space and re-run.
- Ctrl+C: terminate the child process, write a short `last_error`, leave markers untouched, exit 130.

### 9.18 Logging and exit codes

Logs:

- `logs/split.log`, `logs/upscale.log`, `logs/assemble.log`, `logs/run.log`, `logs/doctor.log`.
- Append mode.
- Format: `2026-10-26T12:34:56+01:00 [INFO] message`.
- Include the exact command with quoted arguments.
- Include `VK_ICD_FILENAMES` when set.
- On error, include the last 50 lines of child stderr and the log path.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Unexpected/general error |
| 2 | Usage error |
| 3 | Missing dependency (FFmpeg, ffprobe, Upscayl, models) |
| 4 | Invalid input, job, or settings |
| 5 | Insufficient disk space |
| 6 | Upscayl/upscale failure |
| 7 | FFmpeg encode/mux failure |
| 8 | Output validation failure |
| 130 | Interrupted by Ctrl+C |

V2 returns the same codes.

---

## 10. Presets and hardware matrix

### 10.1 Presets

| Preset | Container | Video | Default audio | Default subtitles | Intended use |
|---|---|---|---|---|---|
| `mp4-h264` | MP4 | H.264, 8-bit | `auto` (AAC if needed) | `auto` (mov_text for text) | Maximum compatibility |
| `mp4-hevc` | MP4 | HEVC, 8-bit | `auto` | `auto` | Smaller files, modern devices |
| `mkv-hevc` | MKV | HEVC, 8-bit | `copy` (first track) | `copy` | Archive, image subtitles, optional all audio tracks with `--all-audio` |
| `mov-prores` | MOV | ProRes 422 HQ, 10-bit 4:2:2 | `pcm` | `copy`/`convert` | Editing in Premiere/Resolve/FCP |

All presets accept `--audio`, `--subs`, `--encoder`, `--quality`, and `--crf` overrides.

### 10.2 Hardware matrix

| Task | NVIDIA | AMD | CPU |
|---|---|---|---|
| Decode frames | `-hwaccel cuda` | `-hwaccel d3d11va` (Windows), VAAPI (Linux) | default |
| H.264 encode | `h264_nvenc` | `h264_amf` | `libx264` |
| HEVC encode | `hevc_nvenc` | `hevc_amf` | `libx265` |
| ProRes encode | CPU only | CPU only | `prores_ks` |
| Upscayl | Vulkan via `upscayl-bin` | Vulkan via `upscayl-bin` | Vulkan via SwiftShader (not recommended) |

- `--encoder auto` order: NVIDIA, AMD, CPU.
- `--decode auto` uses a per-job 30-frame benchmark, not a fixed preference.
- If no GPU is available, everything falls back to CPU (except Upscayl, which requires Vulkan; SwiftShader is a last resort and is not selected automatically).

### 10.3 Quality and speed

- Default: `--quality balanced`.
- `--quality fast` reduces encode time and file size quality; it does not change the Upscayl model.
- `--quality quality` increases encode quality and time.
- Upscayl model choice dominates visual quality:
  - `upscayl-standard-4x`: general-purpose default.
  - `upscayl-lite-4x`: fastest, lower quality; recommended for long videos.
  - `remacri-4x`: live-action detail; slower.
  - `ultramix-balanced-4x`: balanced live-action.
  - `ultrasharp-4x`: sharp; can over-sharpen compressed sources.
  - `high-fidelity-4x`: conservative; less hallucination.
  - `digital-art-4x`: anime/illustration.
- The menu shows these recommendations.

---

## 11. Performance expectations

The tool must set expectations before starting:

- After the first upscale batch, compute frames/second and print an ETA for the whole job.
- If the ETA exceeds 1 hour, print a warning and ask for confirmation (unless `--yes`).
- If the ETA exceeds 12 hours, print a stronger warning and require `--yes` or an explicit confirmation.
- Print the model, scale, tile, batch size, and GPU/CPU choice.

Reference estimates for 1080p → 4K (2x output from a 4x model), 30 fps:

| Model | Approx. per frame | 1 minute (1,800 frames) | 10 minutes | 2 hours |
|---|---|---|---|---|
| `upscayl-standard-4x` | ~1–2 s | 30–60 min | 5–10 h | 60–120 h |
| `upscayl-lite-4x` | ~0.5–1 s | 15–30 min | 2.5–5 h | 30–60 h |

These are estimates from synthetic benchmarks and community reports. Real footage, resolution, tile size, and GPU thermals change them. The tool must not promise exact times.

Disk estimates are printed before split and checked before each batch/chunk.

---

## 12. Testing and acceptance criteria

### 12.1 Test strategy

- Unit tests for pure logic: config/job parsing, fps rationals, frame matching, preset argument builders, disk estimates, path sanitization, encoder selection.
- Integration tests using generated media: no binary fixtures in the repository.
- Cross-version tests: V1 and V2 on the same job folder.
- GPU tests are conditional: run if the encoder/GPU is available; otherwise skip with a clear message.
- Tests use `upscayl-lite-4x`, scale 2, small resolutions (320×240 or 640×360), and batch size 5–10 to keep runtime short.
- Tests must not require network access.

### 12.2 Fixtures

Generate with FFmpeg:

- `clip.mp4`: 5 s, 320×240, 30 fps, H.264 + AAC stereo.
- `clip_noaudio.mp4`: same, no audio.
- `clip_vfr.mkv`: variable frame rate, H.264 + AAC.
- `clip_subs.mkv`: H.264 + MP3 audio + SRT subtitles + chapters.
- `clip_odd.mkv`: 321×241, FFV1 or a PNG sequence muxed into MKV (H.264/yuv420p cannot encode odd dimensions). Tests padding.
- `clip_10bit.mkv`: HEVC 10-bit SDR (tests the high-bit-depth warning).
- `clip_hdr.mkv`: optional HLG/PQ test if generation is reliable; otherwise unit-test the probe logic.
- `clip_long.mp4`: 20 s, 320×240, 30 fps (chunking test).
- A directory with a space and Slovak diacritics in its name: `test diakritika žluťoučký`.
- SRT file for subtitle tests.

### 12.3 Test cases

1. `probe` extracts duration, fps, dimensions, audio, subtitles, color tags.
2. `split` produces the expected number of contiguous frames and a valid `job.txt`.
3. `split` resume after deleting the last 10 frames.
4. `split` with `--start`/`--end` produces the expected frame count.
5. `split` JPEG produces `.jpg` frames.
6. `split` odd dimensions pads to even.
7. `split` detects insufficient disk (mock or tiny `--min-free-gb`) and exits 5.
8. `upscale` with lite model produces the expected number of upscaled frames at 2× dimensions.
9. `upscale` resume after deleting 5 upscaled frames.
10. `upscale` recovers a leftover batch directory.
11. `upscale` rejects a model change without `--force`.
12. Manual GUI naming: rename outputs with `_upscayl_4x_...` suffix; assemble succeeds.
13. Duplicate manual outputs produce an error; `--pick newest` resolves.
14. `assemble` MP4 H.264 CPU, audio copy: duration ±0.1 s, video + audio streams.
15. `assemble` MP4 HEVC CPU, AAC: correct codec tags, `hvc1`.
16. `assemble` MKV HEVC, MP3 copy, SRT copy: three streams, subtitle codec `subrip`.
17. `assemble` MP4 with SRT: subtitle codec `mov_text`.
18. `assemble` MP4 with PGS/image subs: warning and no subtitle stream (or error with `--subs copy`).
19. `assemble` MOV ProRes: `prores` codec, 10-bit 4:2:2, PCM audio.
20. `assemble` no audio: no audio stream.
21. `assemble` trimmed job: audio and video start at 0 and duration matches the range.
22. HDR source without `--tonemap`: exit 4 with a clear message. 10-bit SDR source: succeeds with a precision-loss warning.
23. `run` all-in-one on `clip.mp4`: final output valid.
24. `run --cleanup`: frames/upscaled/chunks gone, output remains.
25. `run` on a 20 s clip with `--chunk-seconds 10`: final duration ±0.1 s, audio present, no chunk dirs left (unless `--keep-chunks`).
26. `run` on two videos: two job folders, two outputs, summary table.
27. `run` continues after one bad video (default) and exits nonzero.
28. `status` prints the expected stages.
29. `clean --all-intermediates` deletes only intermediates; `clean --include-output` deletes output; source remains.
30. `clean` refuses a non-job folder.
31. `doctor` passes on the target machine (exit 0). With a deliberately wrong `upscayl_bin`, it prints a warning and still exits 0 if FFmpeg is usable; `upscale` then exits 3.
32. `doctor` detects the AMD ICD problem when the ICD override is disabled (if reproducible) and prints the workaround.
33. `--dry-run` creates no files.
34. Paths with spaces and diacritics work for split/upscale/assemble.
35. V1 split → V2 assemble and V2 split → V1 assemble.
36. V2 Windows and V2 Unix produce the same `job.txt` keys and output properties.
37. Ctrl+C leaves a resumable job and exits 130.
38. Invalid flags exit 2 with usage.
39. `--force` overwrites an existing output. Without it, the default output path appends `_1`; an explicit `--output FILE` refuses with exit 4 and suggests `--force`.
40. `--10bit` H.264 exits 4; HEVC produces `yuv420p10le`.

### 12.4 Acceptance criteria

A release is acceptable when:

- `doctor` passes on the target machine (after the documented ICD workaround).
- `run` on a 5-second 1080p clip produces a playable 4K MP4 with audio, correct duration, correct fps, and no double rotation.
- Split-only + manual GUI upscale + assemble works, including suffixed filenames.
- Audio copy, AAC, PCM, and no-audio paths work.
- MP3, WAV, and AAC audio inputs work.
- MP4 and MKV subtitle paths work; image subtitles produce a clear warning.
- ProRes output works on CPU.
- NVENC and AMF encode paths work when available; CPU fallback works.
- Chunked processing of a 20-second clip keeps audio sync and bounded disk use.
- Resume works after an interrupted split and an interrupted upscale.
- V2 PowerShell and V2 bash pass the same integration tests as V1.
- No test leaves files outside its temporary/work directory.
- All documentation examples are copy-paste correct.

---

## 13. Limitations and risks

| Risk | Mitigation |
|---|---|
| Upscayl is slow; long videos take hours/days | ETA, warnings, lite model recommendation, chunking; do not promise speed |
| Upscayl memory leak | Restart per batch; batch size 100/50; retry with smaller batch |
| Vulkan enumeration fails due to AMD driver | NVIDIA ICD override; `doctor`; troubleshooting doc; no driver modification |
| GPU OOM with 4K tiles | VRAM-based tile; retry with halved tile; logs |
| Disk exhaustion | Sample-based estimate; chunking; free-space checks; cleanup; `--max-work-gb` |
| Chunk concat incompatibility | MPEG-TS intermediates; MKV fallback; clear error; option to disable chunking |
| Audio copy incompatibility | Container whitelist; AAC fallback in `auto`; explicit errors in `copy` |
| Subtitle conversion loss | Warn; recommend MKV for image/styled subtitles; no burning |
| HDR/10-bit mismatch | HDR rejected by default; `--tonemap` for SDR; 10-bit SDR downconverted with a warning; `--10bit` only for final HEVC SDR |
| VFR timing drift | CFR extraction at avg fps; document the conversion |
| Anamorphic / non-square pixels | The pipeline preserves coded dimensions and outputs square pixels; it does not correct display aspect ratio. Pre-normalize anamorphic sources. |
| AI artifacts/hallucination | Documentation: upscaling is not restoration; recommend conservative models |
| GUI filename changes | Numeric-prefix parser; duplicate resolution; manual mode documented |
| Long paths on Windows | Keep job IDs short; warn above 240 characters; suggest a shorter work dir |
| PowerShell execution policy | `.bat` launcher uses `-ExecutionPolicy Bypass` for the script; document the policy |
| macOS bash 3.2 | Avoid bash 4 features; test on bash 3.2 syntax; use POSIX tools |
| Two codebases drift | Shared contract; cross-version tests; parity checklist in every release |
| Existing projects overlap | Honest prior-art section; focus on completeness and Windows/no-Python support |

---

## 14. Documentation and repository

### 14.1 README.md (English)

Sections:

1. What it does (with a short diagram).
2. Requirements (FFmpeg, Upscayl, Python for V1; PowerShell/bash for V2).
3. Quick start for Windows and Unix.
4. The two versions (V1 vs V2).
5. Common workflows (run, split-only + GUI, long video, target height, ProRes).
6. Presets table.
7. Models and recommendations.
8. Performance and disk expectations.
9. Troubleshooting (link to docs).
10. Limitations.
11. Prior art and credits.
12. License.

### 14.2 docs/USAGE.md

Every command, every flag, defaults, examples, exit codes, and the `job.txt`/`config.txt` formats.

### 14.3 docs/TROUBLESHOOTING.md

- `vkEnumeratePhysicalDevices failed 5` / `Invalid GPU Device`:
  - cause: AMD Vulkan ICD;
  - fix: update the AMD driver; or use the tool's NVIDIA ICD override; or `--icd <path>`;
  - how to find `nv-vk64.json`;
  - how `doctor` detects it.
- `upscayl-bin` not found.
- Models missing.
- GPU OOM.
- Upscayl crashes after N frames.
- Disk full.
- Audio copy fails.
- Image subtitles cannot be converted.
- HDR not supported.
- Long paths.
- PowerShell execution policy.
- macOS `bash` version.
- FFmpeg `glob` not supported (not required).

### 14.4 docs/PERFORMANCE.md

- Benchmark methodology.
- The table from section 11.
- Notes on synthetic vs real footage.
- How to measure your own job (`--verbose`, logs).
- Why tile auto was slow on the target GPU.

### 14.5 Repository files

- `LICENSE`: MIT, copyright 2026 DracieVajko.
- `CHANGELOG.md`: keep a simple "Unreleased" section.
- `.gitignore`:
  ```
  work/
  input/
  output/
  *.log
  batch_*/
  __pycache__/
  .pytest_cache/
  .venv/
  ```
- `config.example.txt`.
- No binaries, models, or sample videos committed.

### 14.6 Publication

- The repository is initialized locally.
- **No GitHub remote, no push, and no Upscayl discussion post until the user explicitly asks.** The user chose "local only" for now.
- When publication is requested:
  - create `DracieVajko/upscayl-video-pipeline`;
  - push `main` and a `v0.1.0` tag;
  - post a concise comment in Upscayl Discussion #542 (not a PR to the C++ repository);
  - mention prior art and the specific Windows/NVIDIA ICD fix;
  - do not claim that Upscayl maintainers endorse the tool.

---

## 15. Implementation phases

Each phase must be independently testable and committed.

### Phase 0 — Scaffold and fixtures

- Create the repository structure, license, README stub, config example, `.gitignore`.
- Add the spec.
- Add fixture generation and the test harness skeleton.
- Verify `git status` is clean.

### Phase 1 — V1 foundation

- `util.py`: logging, subprocess wrappers, path safety, errors, exit codes.
- `config.py`: `config.txt` parsing and defaults.
- `job.py`: job creation/reuse, `job.txt`, `source.txt`, markers, status.
- `probe.py`: FFprobe JSON parsing, fps rationals, stream/color metadata.
- `frames.py`: extraction, counting, validation, resume.
- `disk.py`: sample estimate, free space, chunk decision.
- `doctor.py`: dependency and environment checks (without the Upscayl smoke test initially).
- `split` command end-to-end.
- Unit tests for parsing, fps, job, frames, disk.

### Phase 2 — V1 encode and assemble

- `encode.py`: presets, encoder selection/smoke tests, audio mapping, subtitle mapping, color/rotation, validation.
- `assemble` command for non-chunked jobs.
- Manual GUI filename matching and duplicate resolution.
- CPU, NVENC, AMF, ProRes.
- Tests for all presets, audio modes, subtitle modes, no-audio, trim, odd dimensions.

### Phase 3 — V1 upscale and run

- `upscayl.py`: discovery, model validation, ICD detection, tile/batch sizing, batching, resume, smoke test.
- `run` command: split + upscale + assemble, multi-video, summary, `--cleanup`.
- `doctor` Upscayl smoke test.
- Tests for upscale, resume, GPU fallback, manual GUI mode, `run`.

### Phase 4 — V1 advanced

- Chunking: exact frame accounting, per-chunk encode, concat, mux, cleanup.
- `status`, `clean`, `menu`, `--dry-run`, `--force`, `--yes`.
- ETA/warnings.
- Full V1 integration and edge-case tests.
- Performance documentation.

### Phase 5 — V2 Windows parity

- `UpscaylVideo.ps1` + `.bat`: all commands, flags, defaults, exit codes, menu.
- Same job/config contract.
- PowerShell tests: split, upscale, assemble, run, chunking, resume, paths with spaces/diacritics, GPU/CPU.
- Cross-version tests with V1.

### Phase 6 — V2 Unix parity

- `v2/unix/upscayl-video.sh`: bash 3.2-compatible, all commands and flags, menu.
- Tests on Git Bash/Linux; syntax check with `bash -n`; optional `shellcheck`.
- Cross-version tests with V1.
- macOS-specific checks for `sed`, `date`, `stat`, `df`, and `find`.

### Phase 7 — Final QA and documentation

- Run the full acceptance matrix on the target machine.
- Test a real 1080p clip end-to-end (manual QA).
- Verify audio sync, subtitles, rotation, color, ProRes, NVENC/AMF, chunking, cleanup.
- Complete README, USAGE, TROUBLESHOOTING, PERFORMANCE, CHANGELOG.
- Final spec self-review and update.
- Local git tag `v0.1.0`.
- No publication unless requested.

---

## 16. Resolved decisions

| Decision | Choice |
|---|---|
| Repository name | `upscayl-video-pipeline` |
| License | MIT |
| UI/docs language | English |
| Publication | Local only for now |
| V1 | Python 3.10+ stdlib, modular |
| V2 | PowerShell 5.1+ (Windows) and bash 3.2+ (Unix), full parity, single-file per platform |
| Shared contract | `job.txt` / `config.txt`, key=value, UTF-8 |
| Default model | `upscayl-standard-4x` |
| Default scale | 2 |
| Default preset | `mp4-h264` |
| Default encoder | `auto` (NVIDIA → AMD → CPU) |
| Default decode | `auto` (30-frame CPU/GPU benchmark per job) |
| Default tile | VRAM-based: 128 / 256 / 512 |
| Default batch size | 100 frames (50 for >8 MP frames) |
| Default chunking | `auto` in `run`: enabled if estimate > 40 GB or the free-space floor would be violated |
| Default audio | First track, `auto` (copy if compatible, else AAC 192k) |
| Default subtitles | All tracks, `auto` (copy in MKV, `mov_text` in MP4/MOV for text) |
| Default cleanup | Off; `--cleanup` after successful assemble |
| Menu | Yes, when no args and a TTY |
| Parallel jobs | No, sequential by default |
| HDR | Reject by default; `--tonemap` to SDR; 10-bit SDR downconverted with a warning |
| VFR | Convert to CFR |
| Frame format | PNG default; JPEG optional |
| Output validation | `ffprobe` after assemble; nonzero exit on failure |
| Publication to Upscayl | Not now; discussion #542 only if the user asks later |

---

## Appendix A — Example FFmpeg commands used by the implementation

These are reference shapes, not final code. For brevity, the examples use `-map 1:s?` and `-map_chapters 1`; the implementation maps only the subtitle streams selected by section 9.13 and adds chapters only when the source has them.

### A.1 Split (CPU, PNG)

```bat
ffmpeg -hide_banner -nostdin -y -benchmark ^
  -i "input.mp4" ^
  -map 0:v:0 -an -sn -dn ^
  -fps_mode cfr -r 30000/1001 ^
  -start_number 1 ^
  -compression_level 3 ^
  "work\job\frames\frame_%08d.png"
```

### A.2 Chunk extraction (internal to `run`)

```bat
ffmpeg -hide_banner -nostdin -y -benchmark ^
  -ss 60.000 -i "input.mp4" -t 60.000 ^
  -map 0:v:0 -an -sn -dn ^
  -fps_mode cfr -r 30000/1001 ^
  -start_number 1801 ^
  -frames:v 1800 ^
  -compression_level 3 ^
  "work\job\frames\frame_%08d.png"
```

### A.3 Upscale one batch (NVIDIA ICD)

```bat
set "VK_ICD_FILENAMES=C:\Windows\System32\DriverStore\FileRepository\nv...\nv-vk64.json"
"C:\Program Files\Upscayl\resources\bin\upscayl-bin.exe" ^
  -i "work\job\batch_0001\in" ^
  -o "work\job\batch_0001\out" ^
  -m "C:\Program Files\Upscayl\resources\models" ^
  -n upscayl-standard-4x ^
  -s 2 ^
  -g 0 ^
  -t 256 ^
  -j 1:2:2 ^
  -f png ^
  -c 0
```

### A.4 Assemble MP4 H.264 with audio and subtitles

```bat
ffmpeg -hide_banner -nostdin -y -benchmark ^
  -framerate 30000/1001 -start_number 1 ^
  -i "work\job\upscaled\frame_%08d.png" ^
  -i "input.mp4" ^
  -map 0:v:0 -map 1:a:0? -map 1:s? -map_chapters 1 ^
  -c:v h264_nvenc -preset p6 -tune hq -rc vbr -cq 20 -b:v 0 ^
  -pix_fmt yuv420p ^
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv ^
  -c:a copy ^
  -c:s mov_text ^
  -metadata:s:v:0 rotate=0 ^
  -map_metadata 1 ^
  -movflags +faststart ^
  -t 5.000000 ^
  "work\job\output\input_upscaled.mp4"
```

### A.5 Assemble MKV HEVC with copied audio and subtitles

```bat
ffmpeg -hide_banner -nostdin -y -benchmark ^
  -framerate 30000/1001 -start_number 1 ^
  -i "work\job\upscaled\frame_%08d.png" ^
  -i "input.mkv" ^
  -map 0:v:0 -map 1:a:0? -map 1:s? -map_chapters 1 ^
  -c:v libx265 -preset medium -crf 22 -pix_fmt yuv420p ^
  -c:a copy ^
  -c:s copy ^
  -metadata:s:v:0 rotate=0 ^
  -map_metadata 1 ^
  -t 5.000000 ^
  "work\job\output\input_upscaled.mkv"
```

### A.6 ProRes 422 HQ

```bat
ffmpeg -hide_banner -nostdin -y -benchmark ^
  -framerate 30000/1001 -start_number 1 ^
  -i "work\job\upscaled\frame_%08d.png" ^
  -i "input.mov" ^
  -map 0:v:0 -map 1:a:0? -map_chapters 1 ^
  -c:v prores_ks -profile:v 3 -vendor apl0 -pix_fmt yuv422p10le ^
  -c:a pcm_s24le ^
  -metadata:s:v:0 rotate=0 ^
  -movflags +faststart ^
  -t 5.000000 ^
  "work\job\output\input_upscaled.mov"
```

---

## Appendix B — Installed model notes

| Model | Recommendation |
|---|---|
| `upscayl-standard-4x` | Default for mixed/general live action |
| `upscayl-lite-4x` | Fastest; long videos; lower quality |
| `remacri-4x` | Live action with fine detail; slower |
| `ultramix-balanced-4x` | Balanced live action |
| `ultrasharp-4x` | Sharp results; risk of over-sharpening compressed video |
| `high-fidelity-4x` | Conservative, less hallucination |
| `digital-art-4x` | Anime, illustration, game art |

The tool must list models dynamically from the selected models directory; the table above is only guidance.

---

## Appendix C — Environment verification log

Commands used during design research:

```powershell
# Upscayl CLI help
& "C:\Program Files\Upscayl\resources\bin\upscayl-bin.exe"

# FFmpeg encoders
.\ffmpeg.exe -hide_banner -encoders

# GPU
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader

# Vulkan failure
& "C:\Program Files\Upscayl\resources\bin\upscayl-bin.exe" -i frames -o out -m models -n upscayl-lite-4x ...

# Workaround
$env:VK_ICD_FILENAMES = "C:\WINDOWS\System32\DriverStore\FileRepository\nvacsi.inf_amd64_...\nv-vk64.json"
```

Results are summarized in section 5. No system settings were changed during research.

---

## Appendix D — Open questions

None. All design decisions are resolved in section 16. If the user requests a change during implementation, it must be recorded in this spec before the affected phase starts.
#   S U P E R S E D E D   N O T E  
 T h i s   s p e c   i s   s u p e r s e d e d   b y   d o c s / U S A G E . m d ,   C H A N G E L O G . m d ,   a n d   R E A D M E . m d   a s   o f   r e l e a s e   0 . 3 . 2 .   C o m p o n e n t   l i s t   u p d a t e d   b e l o w .  
 U p d a t e d   c o m p o n e n t s :   c l i ,   c o n f i g ,   j o b ,   p r o b e ,   f r a m e s ,   u p s c a y l ,   e n c o d e ,   d i s k ,   c h u n k i n g ,   p i p e l i n e ,   d o c t o r ,   m e n u ,   m o d e l _ t e s t ,   w o r k s p a c e ,   p r o g r e s s ,   u t i l ,   e r r o r s   ( 1 6   m o d u l e s )  
 U p d a t e d   c o m m a n d s :   d o c t o r ,   s p l i t ,   s p l i t - a l l ,   m o d e l - t e s t ,   u p s c a l e ,   a s s e m b l e ,   f i n i s h ,   r u n ,   s t a t u s ,   c l e a n   ( 1 0   c o m m a n d s )  
 