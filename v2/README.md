# V2 — native implementation (optional)

V2 is the no-Python, no-Node, no-`jq` implementation of the pipeline. It
accepts the same commands, flags, folder layout, `job.txt`/`config.txt`
contract, presets, audio/subtitle rules, exit codes, chunking, resume, doctor
and menu as V1.

V2 is optional. V1 lives in the repository root and does not need this folder;
if you use only V1, delete `v2/` and nothing else changes. V2 reads
`config.txt` from the repository root and uses the same `work/` directory, so
on Windows either version can finish a job created by the other.

## Files

```
v2/
  windows/
    UpscaylVideo.ps1        entry point (PowerShell 5.1+)
    UpscaylVideo.bat        launcher
    modules/                implementation modules, dot-sourced by the entry point
  unix/
    upscayl-video.sh        entry point (bash 3.2+)
    lib/                    implementation modules, sourced by the entry point
  tests/
    Test-V2.ps1             PowerShell test harness
    Test-V2.sh              bash test harness
    Run-Parity.ps1          V1 <-> V2 cross-version matrix
    Run-Parity.sh           V1 <-> V2 cross-version matrix (bash)
```

### Modules

Both runtimes are split into the same 17 modules, with the same responsibilities
in the same place, so the two implementations can be read side by side:

| Module | Responsibility |
|---|---|
| `errors` | The shared exception type (PowerShell only) |
| `core` | Logging, error reporting, process invocation |
| `paths` | File, path, key/value and formatting helpers |
| `config` | Configuration loading and tool resolution |
| `media` | Media probing (ffprobe) |
| `jobs` | The `job.txt` contract |
| `frames` | Frame sets and disk estimates |
| `split` | Input resolution and frame extraction |
| `encode` | Presets, encoders, audio/subtitle plans, encode commands |
| `assemble` | Output paths, publishing, frame reconstruction |
| `upscayl` | Upscayl discovery, model lists, batching, upscaling |
| `chunking` | Chunk planning and segment concatenation |
| `run` | The all-in-one run |
| `admin` | `split-all`, `finish`, `status`, `clean` |
| `doctor` | Environment checks |
| `menu` | Interactive menu |
| `cli` | Option parsing and command dispatch |

The entry points keep their names and their behaviour, including the
`UPSCAYL_V2_LIB=1` mode that the test harnesses use to load the runtime as a
library instead of running a command.

## Requirements

- Windows: PowerShell 5.1+.
- Linux/macOS: bash 3.2+ and POSIX tools.
- FFmpeg and ffprobe.
- Upscayl's `upscayl-bin` and models for `upscale`/`run`. `split`, `assemble`
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

Every V1 flag is accepted, except `model-test`, which is a manifest-only stub
here. The full reference is [`../docs/USAGE.md`](../docs/USAGE.md); verified
behaviour is recorded in [`../docs/VALIDATION.md`](../docs/VALIDATION.md), and
the differences to V1 are listed in [`../docs/PARITY.md`](../docs/PARITY.md).

## Standalone use

The runtime needs only this folder, FFmpeg and Upscayl. The launchers resolve
the tool root as two levels above the script:

- `v2/windows/UpscaylVideo.ps1` → repository root
- `v2/unix/upscayl-video.sh` → repository root

If you copy `v2/` elsewhere, that root becomes the parent of the copied folder.
Either put `config.txt` there or pass `--config PATH` and `--work-dir PATH`
explicitly. The modules are loaded relative to the entry point, so the whole
folder has to be copied.

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

The V2 runtimes never call Python, Node or `jq`. The test harnesses may use
Python only to drive V1 for the parity checks. The test scripts assume the full
repository layout, not a copied `v2/` folder.

The same checks run in CI on every push: PSScriptAnalyzer and the PowerShell
harness on Windows, ShellCheck and the bash harness on Linux, and a bash 3.2
syntax check on macOS.

## Known differences

- `split-all`, `finish` and `model-test` exist in both runtimes. The V2
  `model-test` is a manifest-only stub; it does not run Upscayl.
- Console progress is simpler in V2 (batch counts) and debug commands go to
  stderr.
- On Unix, `--icd auto` does not auto-select an NVIDIA ICD, matching V1; use
  `--icd PATH` when needed.
- V2 jobs use native paths for the current OS. A job created under Git Bash
  with POSIX paths is not directly consumable by a Windows-native V1; jobs are
  not portable across operating systems by design.
- The bash implementation was validated on Git Bash for Windows and with
  `bash -n` syntax checks targeting bash 3.2. Native Linux/macOS execution and
  macOS bash 3.2 are not yet part of the recorded validation.
