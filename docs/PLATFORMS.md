# Platforms

The pipeline has two implementations. V1 runs anywhere Python 3.10+ runs; V2
runs natively on Windows with PowerShell and on Linux and macOS with bash.
This guide covers the differences that matter in practice.

## Windows

### What you need

- **V1:** Python 3.10 or newer. Check with `python --version`.
- **V2:** PowerShell 5.1 or newer — present on Windows 10 and later. Check
  with `$PSVersionTable.PSVersion`.
- FFmpeg and ffprobe. A common installation is `C:\FFMPEG\ffmpeg.exe`.
- Upscayl with its `upscayl-bin.exe` for the automated commands.

### Running V1

```bat
upscayl-video.bat doctor
upscayl-video.bat split "clip.mp4" --work-dir "D:\UpscaylVideo"
upscayl-video.bat assemble "D:\UpscaylVideo\clip" --preset mp4-h264
```

`upscayl-video.bat` forwards the exit code of the Python process, so scripts
can branch on it.

### Running V2

```bat
v2\windows\UpscaylVideo.bat doctor
v2\windows\UpscaylVideo.bat run "clip.mp4" --preset mp4-hevc --cleanup
```

### Windows specifics

- **Paths.** Backslashes are fine; quote any path that contains spaces.
- **The Vulkan ICD workaround.** The AMD Vulkan driver on some systems breaks
  device enumeration (`vkEnumeratePhysicalDevices failed 5`). `--icd auto`
  looks for the NVIDIA Vulkan ICD and passes it to Upscayl. If it does not help,
  pass the JSON file explicitly with `--icd PATH`.
- **GPU probing.** V1 probes the GPU through `wmic`, which is deprecated on
  recent Windows versions; a failed probe simply means the VRAM-based tile size
  cannot be derived, and `--tile` can be set manually.
- **Long paths.** Enable long path support in Windows if you work with deeply
  nested work directories.

### V1 and V2 on Windows together

Both read the same `config.txt` and the same `work/` directory, so a job split
by one version can be assembled by the other. That property is verified
automatically by `v2/tests/Run-Parity.ps1`, which runs in CI on every push.

## Linux and macOS

### What you need

- **V1:** Python 3.10 or newer (`python3 --version`).
- **V2:** bash 3.2 or newer. macOS ships bash 3.2; do not replace it with
  bash 5, because the runtime deliberately avoids features that bash 3.2 does
  not have.
- FFmpeg and ffprobe. On Debian and Ubuntu: `sudo apt install ffmpeg`; on
  Fedora: `sudo dnf install ffmpeg`; on macOS: `brew install ffmpeg`.
- Upscayl with its `upscayl-bin` binary.

### Running V1

```bash
./upscayl-video.sh doctor
./upscayl-video.sh split "clip.mp4" --work-dir "$HOME/UpscaylVideo"
./upscayl-video.sh assemble "$HOME/UpscaylVideo/clip" --preset mp4-h264
```

### Running V2

```bash
bash v2/unix/upscayl-video.sh doctor
bash v2/unix/upscayl-video.sh run "clip.mp4" --preset mp4-hevc --cleanup
```

### Linux and macOS specifics

- **Paths are POSIX.** `/home/user/...` — and unlike on Windows, a path with
  spaces has to be quoted in every shell command.
- **`config.txt`** is read from the repository root; the same file format is
  used on every platform, so a configuration can be shared.
- **The Vulkan ICD.** `--icd auto` does not pick an NVIDIA ICD on Unix, the
  same as V1. Pass `--icd PATH` when the automatic detection is not enough.
- **Job portability.** `job.txt` stores native paths, so a job created on one
  operating system cannot be finished on another. This is by design.
- **macOS and bash 3.2.** The runtime avoids `set -u` and other bash 4+
  features so it keeps working with the bash 3.2 that macOS ships. CI checks
  every script against the system bash on macOS.

## Validation status

| Runtime | Platform | Status |
|---|---|---|
| V1 (Python) | Windows | Fully tested, including the integration tests with real FFmpeg |
| V1 (Python) | Linux | Tested in CI with real FFmpeg |
| V1 (Python) | macOS | Not executed in CI; no runner available for it |
| V2 (PowerShell) | Windows | Fully tested, including the cross-version parity matrix |
| V2 (bash) | Windows (Git Bash) | Unit tests and syntax checks pass |
| V2 (bash) | Linux | Syntax checks and the unit tests pass in CI |
| V2 (bash) | macOS | Syntax check with bash 3.2 in CI |

The precise, dated record of every test run is in
[VALIDATION.md](VALIDATION.md). No GPU behaviour is claimed for a platform
where no GPU run was executed.
