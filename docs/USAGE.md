# Usage — V1 core

The V1 core covers two workflows:

1. **Split only** → upscale manually in the Upscayl GUI → **assemble**.
2. **Split** and **assemble** with a different external upscaler.

Automated `upscale`, `run`, chunking, and the full menu are implemented in the
next plan and are not part of this build.

## Requirements

- Python 3.10 or newer.
- FFmpeg and ffprobe. Either put them in `PATH`, set `ffmpeg=`/`ffprobe=` in
  `config.txt`, or pass `--ffmpeg`/`--ffprobe`.
- Upscayl is **not required** for the core: it is used manually in its GUI.

## Quick start

```bash
# Windows
upscayl-video.bat doctor --ffmpeg "C:\FFMPEG\ffmpeg.exe" --ffprobe "C:\FFMPEG\ffprobe.exe"

# Linux/macOS
./upscayl-video.sh doctor

# Split one video
upscayl-video split "clip.mp4" --work-dir "D:\UpscaylVideo"

# In Upscayl: input  D:\UpscaylVideo\clip\frames
#             output D:\UpscaylVideo\clip\upscaled

# Assemble
upscayl-video assemble "D:\UpscaylVideo\clip" --preset mp4-h264 --encoder auto
```

## Commands

### `doctor`

```bash
upscayl-video doctor [--skip-upscayl-smoke] [--verbose]
```

Checks FFmpeg/ffprobe versions, available encoders, `zscale`, and the work
directory. Exit codes: `0` OK, `3` a required tool is missing, `5` too little
free space. Upscayl checks are added with the automated upscale stage.

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
- `--start`/`--end` accept `SS`, `MM:SS`, or `HH:MM:SS`.
- `--decode auto` benchmarks CPU and GPU extraction for the job.
- `--tonemap` converts HDR (PQ/HLG) to SDR BT.709 **before** upscaling. HDR is
  rejected without it.
- `--scale` is the Upscayl output scale (2, 3, or 4); it is recorded for the
  later upscale and does not change the extracted frames.
- `--target-height` chooses the smallest scale that reaches the target. The
  assembler downscales to the exact height with Lanczos, using the value stored
  in `job.txt`; you do not need to repeat the flag on `assemble`. Odd values are
  rounded up to an even height.
- `--model` is recorded in `job.txt` for the later upscale.
- `--verify-frames` checks PNG/JPEG magic instead of only file size.
- `--force` rebuilds a job whose settings changed.
- `--dry-run` probes and prints the disk estimate, but creates no job or frames.

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
  extension (`.mp4`, `.mkv`, or `.mov`). The encoder writes a `*.partial.*`
  file and atomically replaces the final output only after validation.
- `--upscaled-dir` points at a custom folder containing Upscayl output.
- Upscayl GUI suffixes such as `_upscayl_4x_upscayl-standard-4x` are accepted.
  Non-standard names are normalized through a temporary `sequence/` folder,
  which is deleted after a successful encode.
- A trimmed job (`--start`/`--end`) seeks the source audio and subtitles too.
  Copied audio is re-encoded as AAC when a trim is active.
- `--cleanup` deletes `frames/`, `upscaled/`, and `sequence/` after a
  successful assemble. The output is kept.
- `--tonemap` is rejected: tonemapping belongs to the split stage.

### `upscale`

```bash
upscayl-video upscale <job...> [--all] \
  [--model NAME] [--scale 2|3|4] [--gpu N] [--tile auto|N] \
  [--batch-size N] [--threads L:P:S] [--icd auto|none|PATH] \
  [--upscayl-bin PATH] [--models-dir DIR] [--upscaled-dir DIR] \
  [--retry N] [--force] [--dry-run]
```

Runs Upscayl's CLI in bounded batches, restarting the process after each batch
to avoid its memory leak. Missing frames are retried; existing valid outputs
are skipped. `auto` tile uses VRAM: 128 for 4 GiB, 256 for 6–8 GiB, 512 above.
`--icd auto` finds the NVIDIA Vulkan ICD on Windows; this is the workaround for
the AMD `vkEnumeratePhysicalDevices failed 5` error.

### `run`

```bash
upscayl-video run <video...> [split/upscale/assemble options] \
  [--chunk-seconds auto|0|N] [--stop-on-error] [--cleanup]
```

One command per video: split → upscale → assemble. Continues to the next input
after a failure unless `--stop-on-error`. `--cleanup` removes intermediates
after success.

### Chunking

`run --chunk-seconds 60` splits a long video into 60-second chunks, upscales and
encodes each chunk separately, concatenates the video-only segments, then muxes
the original audio/subtitles. Chunk intermediates are deleted after each chunk
unless `--keep-chunks`. A completed chunk is skipped on resume.

`--chunk-seconds auto` currently uses the non-chunked path; use an explicit
value (for example `60`) to enable chunking.

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

`--all-intermediates` deletes frames, upscaled frames, chunks, sequence, and
`batch_*` folders. `--include-output` also deletes the final output. The source
video is never deleted. A job outside the work directory is refused.

## Job folder

```
work/<job_id>/
  job.txt
  source.txt
  frames/frame_00000001.png ...
  upscaled/frame_00000001.png ...
  sequence/                  # transient normalized names
  output/<stem>_upscaled.mp4
  logs/
  .done_split
  .done_assemble
```

`job.txt` is a UTF-8 key=value file. It is the shared contract for later
versions; do not edit it while a stage is running.

## Configuration

Copy `config.example.txt` to `config.txt` next to the tool and adjust:

```ini
ffmpeg=C:\FFMPEG\ffmpeg.exe
ffprobe=C:\FFMPEG\ffprobe.exe
work_dir=D:\UpscaylVideo
default_model=upscayl-standard-4x
default_scale=2
default_preset=mp4-h264
default_encoder=auto
default_audio=auto
default_subs=auto
min_free_gb=5
max_work_gb=40
cleanup=0
```

CLI flags override the file. Relative paths in `config.txt` are relative to the
config file.

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
4. Choose the model and scale, then run the batch.
5. `assemble work/<job>`.

Upscayl may create a model-specific subfolder or append a suffix to filenames;
the assembler accepts both. If two files map to the same frame index, use
`--pick newest` or `--pick largest`, or remove the stale copy.

## Not in this build

- Native PowerShell/bash V2 implementation (`v2/`).
- Chunking driven by `auto`; use an explicit `--chunk-seconds N`.
- Frame interpolation and HDR output.
