# Troubleshooting — V1 core

## `ffmpeg` or `ffprobe` not found

Set explicit paths in `config.txt`:

```ini
ffmpeg=C:\FFMPEG\ffmpeg.exe
ffprobe=C:\FFMPEG\ffprobe.exe
```

or pass `--ffmpeg`/`--ffprobe`. The tool also looks next to the project and in
the project's parent directory. `doctor` prints the searched paths.

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

## `--tonemap` is rejected by `assemble`

Tonemapping is a split-stage operation. Re-split with `--tonemap`; it cannot be
applied during assembly because the frames have already passed through Upscayl.

## Automated upscale is missing

This build intentionally covers the manual GUI workflow only. The automated
`upscale`/`run` stage, chunking, and the no-Python V2 implementation are the
next plans.
