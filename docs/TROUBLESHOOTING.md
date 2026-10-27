# Troubleshooting — V1 and V2

## `ffmpeg` or `ffprobe` not found

Set explicit paths in `config.txt`:

```ini
ffmpeg=C:\FFMPEG\ffmpeg.exe
ffprobe=C:\FFMPEG\ffprobe.exe
```

or pass `--ffmpeg`/`--ffprobe`. The tool also looks next to the project and in
the project's parent directory. A missing executable error prints the searched
paths.

## Paths with spaces or non-ASCII characters

The V1 core always passes arguments as a list, not through a shell. Paths with
spaces, `=`, and characters such as `ž`, `ť`, `ů`, `ý` are supported. Job
folders keep Unicode letters; whitespace becomes `_`. If a job folder looks
unexpected, run `status --verbose` to see the full path.

## `Audio codec cannot be copied into mp4`

MP4 cannot hold every audio codec. Use:

```bash
upscayl-video assemble <job> --audio aac
```

or choose `--preset mkv-hevc`, which copies almost any audio codec.

## PCM audio in MP4

PCM is not broadly compatible with MP4. Use `--audio aac` or `mkv-hevc`. ProRes
MOV uses PCM by default.

## Subtitles are missing from MP4

MP4 only supports text subtitles converted to `mov_text`. Image subtitles
(PGS, VobSub, DVB) cannot be converted. The assembler drops them with a warning.
Use `--preset mkv-hevc` to keep image subtitles.

## `HDR source detected`

Upscayl models are 8-bit SDR. Re-split with:

```bash
upscayl-video split "clip.mkv" --tonemap
```

This converts HDR to SDR BT.709 before the frames reach Upscayl. HDR is lost.

## 10-bit SDR source

The frames are converted to 8-bit RGB for Upscayl. This is expected; the tool
warns. `--10bit` on assemble only affects the final HEVC encode and cannot
recover the discarded bits.

## Output validation failed

The encode finished but the result did not match the expected dimensions,
duration, fps, audio, subtitle count, or pixel format. Check
`work/<job>/logs/assemble.log`. The intermediate frames are kept. Re-run
`assemble` after fixing the cause; use `--force` only when you intend to
overwrite an existing output.

## Not enough disk space

Use a work directory on a larger drive:

```bash
upscayl-video split "clip.mp4" --work-dir "D:\UpscaylVideo"
```

The estimate is based on one real sample frame plus a 1 GiB margin. The source
and frames can be large; a 1080p PNG frame is often 1–3 MiB.

## Upscayl output names

Upscayl may write names such as:

```
frame_00000001_upscayl_4x_upscayl-standard-4x.png
```

The assembler detects the eight-digit index and normalizes the names through a
temporary `sequence/` folder. Mixed output formats are rejected; run Upscayl
again with one output format.

## Duplicate frame indices

If an old Upscayl run left files in `upscaled/`, two files can map to the same
index. Remove the stale set, or use:

```bash
upscayl-video assemble <job> --pick newest
```

## Interrupted split

Re-run the same `split` command. It counts contiguous frames and resumes at the
next index. If the remaining files are not contiguous, the tool refuses; use
`--force` to start the job over.

## Python is not found on Windows

Install Python 3.10+ and make sure `py -3` or `python` works. The `.bat`
launcher tries `py -3` first, then `python`.

## V2 PowerShell will not run

Use `v2\windows\UpscaylVideo.bat`, which calls PowerShell with
`-ExecutionPolicy Bypass`. If you run the `.ps1` directly, your execution policy
must allow local scripts, or use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File v2\windows\UpscaylVideo.ps1 doctor
```

## V2 bash on macOS or Linux

Run it with `bash` (not `sh`) so bash 3.2+ features are available:

```bash
bash v2/unix/upscayl-video.sh doctor
```

V2 jobs store paths in the native form for the current OS. A job created under
Git Bash with POSIX paths is not directly consumable by a Windows-native V1;
use one version per OS.

## `--tonemap` is rejected by `assemble`

Tonemapping is a split-stage operation. Re-split with `--tonemap`; it cannot be
applied during assembly because the frames have already passed through Upscayl.

## `vkEnumeratePhysicalDevices failed 5` / `Invalid GPU Device`

The old AMD Vulkan driver can break device enumeration even when an NVIDIA GPU
is present. Try, in order:

1. Update the AMD driver.
2. Set the NVIDIA ICD explicitly:

```bash
upscayl-video upscale <job> --icd "C:\Windows\System32\DriverStore\FileRepository\nv...\nv-vk64.json"
```

3. Put the same path in `config.txt` as `icd=...`.
4. Run `upscayl-video doctor`; it retries with the NVIDIA ICD and reports the
   workaround.

## Upscayl CLI or models not found

Set `upscayl_bin` and `models_dir` in `config.txt`, or pass
`--upscayl-bin`/`--models-dir`. Models need matching `.param` and `.bin` files.
`doctor` lists the discovered paths.

## `Upscayl model directory must be named 'models'`

Upscayl inspects the folder name. Put custom models in a folder called
`models`, for example `D:\AI\UpscaylModels\models`, and point `models_dir` at
that folder. Renaming the parent folder does not help; the folder containing
the `.param`/`.bin` pairs must be `models`.

## Upscayl runs out of memory

`upscale` retries once with half the tile and batch size. If it still fails,
lower `--tile 128` or `--tile 64` and use `--batch-size 10`. Close other GPU
applications. The target machine's 6 GiB card works with tile 256; 4 GiB cards
should use 128.

## Chunk concatenation fails

Chunked run uses MPEG-TS segments for H.264/HEVC and MOV for ProRes, then concat
copy. MKV presets fall back to a Matroska concat when the MPEG-TS path is
rejected. If it still fails, run without chunking (`--chunk-seconds 0`) and
report the exact error.
