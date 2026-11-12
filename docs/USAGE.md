# Usage

The pipeline supports three workflows:

1. **Split only** → upscale manually in the Upscayl GUI → **assemble**.
2. **Split** and **assemble** with a different external upscaler.
3. **Automated `run`**: split → `upscayl-bin` → assemble, with resume and
   chunking.

V1 (Python) and V2 (PowerShell/bash) use the same commands, flags and the
`job.txt`/`config.txt` contract. V2 launchers:

```bat
v2\windows\UpscaylVideo.bat <command> [options]
```

```bash
bash v2/unix/upscayl-video.sh <command> [options]
```

V1 lives in the repository root. V2 is optional and lives in `v2/`; delete that
folder if you only use V1. Both versions read `config.txt` from the repository
root and share `work/`, so on Windows either one can finish the other's jobs.

## Input requirements

- Any container FFmpeg can decode: MP4, MKV, MOV, WebM, AVI, TS, WMV, FLV, MPG,
  MPEG, OGV, MTS.
- One video stream. Audio, subtitle and chapter streams are preserved.
- HDR sources (PQ or HLG) are rejected unless `--tonemap` is given, because the
  pipeline produces SDR output.
- Paths may contain spaces and non-ASCII characters.
- The frames of a long video need a lot of disk space; 1080p PNG frames are
  commonly 1–3 MiB each. `--dry-run` prints an estimate before anything is
  written.

## Installation

```bash
git clone https://github.com/DracieVajko/upscayl-video-pipeline.git
cd upscayl-video-pipeline
cp config.example.txt config.txt
```

- **V1** needs Python 3.10 or newer. Nothing else to install.
- **V2 Windows** needs PowerShell 5.1 or newer (present on Windows 10 and later).
- **V2 Unix** needs bash 3.2 or newer (present on macOS and on most Linux
  distributions).

See [PLATFORMS.md](PLATFORMS.md) for platform-specific notes.

## FFmpeg setup

FFmpeg and ffprobe must be reachable. In order of precedence:

1. the `--ffmpeg` and `--ffprobe` flags,
2. the `ffmpeg` and `ffprobe` keys in `config.txt`,
3. the `PATH`.

```bash
upscayl-video doctor --ffmpeg "C:\FFMPEG\ffmpeg.exe" --ffprobe "C:\FFMPEG\ffprobe.exe"
```

The `doctor` command reports the FFmpeg version, the available encoders, the
`zscale` filter, the free space of the work directory, the Upscayl CLI and its
models, and runs a one-frame smoke encode where possible.

## Upscayl setup

The automated `upscale` and `run` commands need Upscayl's CLI:

- **Windows:** `upscayl-bin.exe` in the Upscayl installation, for example
  `C:\Program Files\Upscayl\resources\bin\upscayl-bin.exe`.
- **Linux/macOS:** the `upscayl-bin` binary that ships with the Upscayl build.

Point `upscayl_bin` at it in `config.txt`, or pass `--upscayl-bin`.

Models are `.param` files with a matching `.bin` file. Upscayl requires the
directory that holds them to be named `models`:

```ini
models_dir=D:\AI\UpscaylModels\models
```

`doctor` and `upscale` report a clear error when the directory is not named
`models`. Splitting, assembling and the manual GUI workflow work without the
Upscayl CLI at all.

On Windows the AMD Vulkan driver can break device enumeration
(`vkEnumeratePhysicalDevices failed 5`). `--icd auto` finds the NVIDIA Vulkan ICD
and works around it; see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Commands

### `doctor`

```bash
upscayl-video doctor [--skip-upscayl-smoke] [--verbose]
```

Checks the FFmpeg/ffprobe versions, the available encoders, `zscale`, the work
directory, Upscayl, the model directory and a one-frame smoke encode where
possible. Exit codes: `0` OK, `3` a required tool is missing, `5` too little
free space.

### `split`

```bash
upscayl-video split <video...> \
  [--fps N] [--start TIME] [--end TIME] \
  [--format png|jpg] [--jpeg-quality 1-31] [--png-compression 0-9] \
  [--denoise none|light|medium|strong] [--tonemap] \
  [--decode cpu|gpu|auto] [--scale 2|3|4] [--target-height N] \
  [--model NAME] [--verify-frames] [--recursive] \
  [--work-dir DIR] [--force] [--dry-run]
```

- `--fps` accepts `29.97` or `30000/1001`.
- `--start`/`--end` accept `SS`, `MM:SS` or `HH:MM:SS`.
- `--decode auto` benchmarks CPU and GPU extraction for the job.
- `--tonemap` converts HDR (PQ/HLG) to SDR BT.709 **before** upscaling. HDR is
  rejected without it.
- `--scale` is the Upscayl output scale (2, 3 or 4); it is recorded for the
  later upscale and does not change the extracted frames.
- `--target-height` chooses the smallest scale that reaches the target. The
  assembler downscales to the exact height with Lanczos, using the value stored
  in `job.txt`; you do not need to repeat the flag on `assemble`. Odd values are
  rounded up to an even height.
- `--model` is recorded in `job.txt` for the later upscale.
- `--verify-frames` checks PNG/JPEG magic instead of only the file size.
- `--force` rebuilds a job whose settings changed.
- `--dry-run` probes and prints the disk estimate, but creates no job or frames.

### `split-all`

```bash
upscayl-video split-all [--format png|jpg] [--png-compression N] \
  [--jpeg-quality N] [--denoise none|light|medium|strong] \
  [--decode cpu|gpu|auto] [--tonemap|--no-tonemap] \
  [--scale 2|3|4] [--model NAME] [--dry-run] [--yes]
```

Scans `input_dir` (default `input` next to `config.txt`), splits every video
into `work/<job>/batch00001/in`, extracts every audio track to
`work/<job>/audio`, creates `batch00001/out`, and writes `work/manifest.csv`
plus `work/README-UPScayl.txt`. HDR is tonemapped by default. Point the Upscayl
GUI at `batch00001/in` and `batch00001/out`.

### `upscale`

```bash
upscayl-video upscale <job...> [--all] \
  [--model NAME] [--scale 2|3|4] [--gpu N] [--tile auto|N] \
  [--batch-size N] [--threads L:P:S] [--icd auto|none|PATH] \
  [--upscayl-bin PATH] [--models-dir DIR] [--upscaled-dir DIR] \
  [--retry N] [--force] [--dry-run]
```

Runs the Upscayl CLI in bounded batches, restarting the process after each
batch to avoid its memory leak. Missing frames are retried; existing valid
outputs are skipped. Accepts one job folder or the work directory. `auto` tile
uses VRAM: 128 for 4 GiB, 256 for 6–8 GiB, 512 above.
`--icd auto` finds the NVIDIA Vulkan ICD on Windows; this is the workaround for
the AMD `vkEnumeratePhysicalDevices failed 5` error. If the projected time
exceeds one hour, the command asks for confirmation; `--yes` skips the prompt.

### `assemble`

```bash
upscayl-video assemble <job...> [--all] \
  [--preset mp4-h264|mp4-hevc|mkv-hevc|mov-prores] \
  [--encoder auto|nvidia|amd|cpu] [--quality fast|balanced|quality] [--crf N] \
  [--audio auto|copy|aac|pcm|none] [--audio-bitrate N] [--all-audio] \
  [--subs auto|copy|convert|none] [--10bit] \
  [--target-height N] [--output PATH] [--upscaled-dir DIR] \
  [--pick error|newest|largest] [--verify-frames] [--allow-huge] \
  [--cleanup] [--force] [--dry-run]
```

- `--all` assembles every job in the work directory.
- The default output is `work/<job>/output/<source-stem>_upscaled.<ext>`.
  If it exists, the default path gets `_1`, `_2`, ... unless `--force`.
- An explicit `--output FILE` that exists is an error unless `--force`.
- `--audio auto` copies the first audio track when the container supports it,
  otherwise encodes AAC. `--all-audio` selects every track.
- `--subs auto` copies subtitles in MKV and converts text subtitles to
  `mov_text` in MP4/MOV. Image subtitles (PGS/DVD) are dropped in MP4/MOV with
  a warning; use `mkv-hevc` to keep them.
- `--output` must not point at the source video and must use the preset's
  extension (`.mp4`, `.mkv` or `.mov`). The encoder writes a `*.partial.*`
  file and atomically replaces the final output only after validation.
- `--upscaled-dir` points at a custom folder containing Upscayl output.
- Upscayl GUI suffixes such as `_upscayl_4x_upscayl-standard-4x` are accepted.
  Non-standard names are normalized through a temporary `sequence/` folder,
  which is deleted after a successful encode.
- A trimmed job (`--start`/`--end`) seeks the source audio and subtitles too.
  Copied audio is re-encoded as AAC when a trim is active.
- `--cleanup` moves the final video to `output_dir` (default `output` next to
  `config.txt`) and then deletes the whole `work/<job>` folder, leaving `work/`
  empty. The source video is never touched. Use `--output-dir DIR` to choose a
  different destination.
- `--quality` and `--crf` are mutually exclusive; passing both exits with
  code 4.
- `--tonemap` is rejected: tonemapping belongs to the split stage.

### `finish`

```bash
upscayl-video finish [--all] [--job NAME ...] \
  [--profile default|fast|quality] [--preset NAME] \
  [--encoder auto|nvidia|amd|cpu] [--quality fast|balanced|quality] [--crf N] \
  [--audio auto|copy|aac|pcm|none] [--subs auto|copy|convert|none] \
  [--ffmpeg-args "..."] [--keep] [--yes]
```

Assembles jobs from `work/`, moves each video to `output_dir`, and removes the
whole job folder. Without `--all` or `--job`, it lists jobs and asks. `--keep`
keeps the work folder. `--ffmpeg-args` appends extra FFmpeg flags; structural
flags (`-i`, `-map`, `-vf`, `-af`, `-c`, `-ss`, `-f`, `-y`, and the alias
spellings such as `-vcodec`) are rejected; the check matches the base option
name, so `-filter:v:0` is rejected too.

### `run`

```bash
upscayl-video run <video...> [split/upscale/assemble options] \
  [--chunk-seconds auto|0|N] [--keep-chunks] [--stop-on-error] [--cleanup] \
  [--max-work-gb N] [--min-free-gb N] [--yes]
```

One command per video: split → upscale → assemble. Continues to the next input
after a failure unless `--stop-on-error`. `--cleanup` moves the video to
`output_dir` and removes the job folder after success; `--keep-chunks` keeps
per-chunk intermediates.
`--quality` and `--crf` are mutually exclusive. `--max-work-gb` and
`--min-free-gb` override the disk guards from `config.txt`.

### `model-test`

```bash
upscayl-video model-test <video> [--frames 3] [--seed N] \
  [--scale 2|3|4] [--model NAME ...] [--models-dir DIR] \
  [--tile auto|N] [--gpu N] [--icd auto|none|PATH] \
  [--decode cpu|gpu|auto] [--tonemap|--no-tonemap] \
  [--open] [--dry-run] [--yes]
```

Samples `--frames` frames spread across the clip, upscales each one with every
discovered model, and writes an HTML report to
`work/_model_tests/<video>/<timestamp>/report.html`. `--seed` reproduces the
frame choice. `--model` limits the run to named models. The test folder is not
a job; `status` and `clean` ignore it. V1 runs every model. The V2 runtimes
accept the command but only write the manifest skeleton.

### `status`

```bash
upscayl-video status [--verbose]
```

Shows one row per job: stage, frame count, upscaled count, and output file.
Stages: `split`, `upscale`, `assemble`, `done`, `failed`, `empty`.

### `clean`

```bash
upscayl-video clean <job...> [--all-jobs] \
  [--frames] [--upscaled] [--chunks] [--batch] \
  [--all-intermediates] [--include-output] [--dry-run]
```

`--all-intermediates` deletes frames, upscaled frames, chunks, sequence and
`batch_*` folders. `--include-output` also deletes the final output. The source
video is never deleted. A job outside the work directory is refused.

## Frame reconstruction and output settings

- Presets: `mp4-h264`, `mp4-hevc`, `mkv-hevc`, `mov-prores`.
- Encoders: `auto`, `nvidia` (NVENC), `amd` (AMF), `cpu` (libx264/libx265/
  ProRes). `auto` falls back to the CPU when the hardware encoder rejects the
  resolution or format.
- Quality: `--quality fast|balanced|quality` or `--crf N` (mutually exclusive).
  `--10bit` produces 10-bit HEVC; it is invalid with ProRes, which is always
  10-bit.
- Colour: the output is tagged BT.709 with TV range after a tonemap; RGB
  sources fall back to a valid YUV matrix instead of an invalid one.
- The encoder writes to a `*.partial.*` file and replaces the final file only
  after the output validates, so an interrupted run never leaves a broken file
  in place.

## Job folder

`upscale` and `assemble` accept a job folder or the work directory. Passing
the work directory selects every job; the interactive menu lists the jobs and
lets you choose one or all.

```
work/<job_id>/
  job.txt
  audio/
    track01.mka
    info.txt
  batch00001/
    in/frame_00000001.png ...
    out/frame_00000001.png ...
  output/<stem>_upscaled.mp4      # transient; finish publishes it
  logs/
  .done_split
  .done_assemble
```

Older jobs use `frames/` and `upscaled/` instead of `batch00001/in|out`; the
assembly code accepts both. `job.txt` stores `frames_dir` and `upscaled_dir`
relative to the job folder.

`job.txt` is a UTF-8 key=value file. It is the shared contract between the
versions; do not edit it while a stage is running.

## Configuration

Copy `config.example.txt` to `config.txt` in the repository root and adjust.
Both V1 and V2 read this file:

```ini
ffmpeg=C:\FFMPEG\ffmpeg.exe
ffprobe=C:\FFMPEG\ffprobe.exe
upscayl_bin=C:\Program Files\Upscayl\resources\bin\upscayl-bin.exe
models_dir=D:\AI\UpscaylModels\models
work_dir=D:\UpscaylVideo\work
output_dir=D:\UpscaylVideo\output
input_dir=D:\UpscaylVideo\input
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
min_free_gb=5
max_work_gb=40
cleanup=0
```

CLI flags override the file. Relative paths in `config.txt` are relative to
the config file. `models_dir` must point at a folder named `models` containing
matching `.param`/`.bin` pairs.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Unexpected/command failure |
| 2 | Usage error |
| 3 | Missing dependency |
| 4 | Invalid input, job, settings, or output collision |
| 5 | Insufficient disk space |
| 6 | Upscale failure (reserved) |
| 7 | Encode/mux failure |
| 8 | Output validation failure |
| 130 | Interrupted |

## Manual Upscayl GUI workflow

1. `split` the video.
2. In Upscayl, select `work/<job>/frames` as the input folder.
3. Select `work/<job>/upscaled` as the output folder.
4. Choose the model and scale, then run the batch. Custom models must live in a
   folder named `models`; point `models_dir` at it and the menu lists them next
   to the standard models.
5. `assemble work/<job>`.

Upscayl may create a model-specific subfolder or append a suffix to filenames;
the assembler accepts both. If two files map to the same frame index, use
`--pick newest` or `--pick largest`, or remove the stale copy.

## Troubleshooting

Common problems — missing FFmpeg, the Vulkan ICD error, "no frames found",
"not enough free space", Upscayl models not found — are documented in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Known limitations

- Upscayl requires the model directory to be named `models`; point
  `models_dir` at such a folder when using custom models.
- The V2 bash runtime was validated on Git Bash for Windows; native
  Linux/macOS execution is not part of the recorded validation yet. macOS
  bash 3.2 syntax constraints are observed.
- Frame interpolation and HDR output are not supported.
