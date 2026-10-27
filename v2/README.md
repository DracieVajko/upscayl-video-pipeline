# V2 — native implementation

V2 is the no-Python, no-Node, no-`jq` implementation of the pipeline. It uses
the same commands, flags, folder layout, `job.txt`/`config.txt` contract,
presets, audio/subtitle rules, exit codes, chunking, resume, doctor, and
nine-option menu as V1.

- `windows/UpscaylVideo.ps1` — PowerShell 5.1+ implementation.
- `windows/UpscaylVideo.bat` — launcher.
- `unix/upscayl-video.sh` — bash 3.2+ implementation.

## Requirements

- Windows: PowerShell 5.1+.
- Linux/macOS: bash 3.2+ (POSIX tools).
- FFmpeg and ffprobe.
- Upscayl's `upscayl-bin` and models for `upscale`/`run`. `split`, `assemble`,
  and manual GUI upscaling work without the Upscayl CLI.

## Usage

```bat
v2\windows\UpscaylVideo.bat doctor
v2\windows\UpscaylVideo.bat split "clip.mp4"
v2\windows\UpscaylVideo.bat upscale work\clip --model upscayl-lite-4x --scale 2
v2\windows\UpscaylVideo.bat assemble work\clip --preset mp4-h264
v2\windows\UpscaylVideo.bat run "clip.mp4" --preset mp4-hevc --cleanup
v2\windows\UpscaylVideo.bat status
v2\windows\UpscaylVideo.bat clean work\clip --all-intermediates
```

```bash
bash v2/unix/upscayl-video.sh doctor
bash v2/unix/upscayl-video.sh split "clip.mp4"
bash v2/unix/upscayl-video.sh upscale work/clip --model upscayl-lite-4x --scale 2
bash v2/unix/upscayl-video.sh assemble work/clip --preset mp4-h264
bash v2/unix/upscayl-video.sh run "clip.mp4" --preset mp4-hevc --cleanup
bash v2/unix/upscayl-video.sh status
bash v2/unix/upscayl-video.sh clean work/clip --all-intermediates
```

Every flag from V1 is accepted. See [`../docs/USAGE.md`](../docs/USAGE.md) for
the full reference and [`../docs/VALIDATION.md`](../docs/VALIDATION.md) for the
verified behaviour.

## Tests

```powershell
# Windows unit tests (no Pester)
powershell -NoProfile -ExecutionPolicy Bypass -File v2/tests/Test-V2.ps1

# V1 <-> V2 Windows cross-version matrix; generates its own media
powershell -NoProfile -ExecutionPolicy Bypass -File v2/tests/Run-Parity.ps1
```

```bash
# bash unit and optional integration tests
bash v2/tests/Test-V2.sh
RUN_V2_INTEGRATION=1 bash v2/tests/Test-V2.sh
```

The V2 runtimes never call Python, Node, or `jq`. The test harnesses may use
Python only to drive V1 for parity checks.

## Known differences

- Console progress is simpler in V2 (batch counts) and debug commands go to
  stderr.
- On Unix, `--icd auto` does not auto-select an NVIDIA ICD, matching V1; use
  `--icd PATH` when needed.
- V2 jobs use native paths for the current OS. A job created under Git Bash
  with POSIX paths is not directly consumable by a Windows-native V1; jobs are
  not portable across operating systems by design.
- `run --chunk-seconds auto` uses the non-chunked path, matching V1; use an
  explicit value such as `60`.
- The bash implementation was validated on Git Bash for Windows and with
  `bash -n` syntax checks targeting bash 3.2. Native Linux/macOS execution and
  macOS bash 3.2 are not yet part of the recorded validation.
