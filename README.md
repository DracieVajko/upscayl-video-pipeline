# Upscayl Video Pipeline

A local FFmpeg + Upscayl pipeline for upscaling video:

```
video → frames → Upscayl → frames → video (with audio, subtitles, chapters)
```

Two implementations with the same commands and work-folder format:

- **V1:** Python 3.10+ (standard library only), Windows/Unix launchers.
- **V2:** no Python — PowerShell 5.1+ on Windows, bash 3.2+ on Linux/macOS.

**Status:** design phase. The implementation has not started yet. See
[`docs/specs/2026-10-26-upscayl-video-pipeline-design.md`](docs/specs/2026-10-26-upscayl-video-pipeline-design.md)
for the full specification.

## Planned features

- One or many input videos, each with its own work folder.
- Split-only mode for manual Upscayl GUI batch upscaling.
- Automated `upscayl-bin` upscaling in bounded batches (memory-leak safe).
- PNG/JPEG frames, optional denoise.
- MP4 H.264, MP4 HEVC, MKV HEVC, MOV ProRes.
- NVIDIA NVENC, AMD AMF, or CPU encoding; CPU/GPU decoding with a per-job benchmark.
- Audio copy/AAC/PCM/none; multiple audio tracks; subtitles; chapters.
- Chunked processing for long videos, disk estimates, resume, cleanup.
- `doctor` command for dependencies, GPU/Vulkan, encoders, models, and disk.

## Requirements

- FFmpeg and ffprobe.
- Upscayl with `upscayl-bin` and models (for the automated upscale stage).
- V1: Python 3.10+.
- V2: Windows PowerShell 5.1+ or bash 3.2+.

## License

MIT. Upscayl is a separate AGPL-3.0 project; its models are not distributed here.
