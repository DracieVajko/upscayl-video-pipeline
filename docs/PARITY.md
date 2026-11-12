# V1 ↔ V2 parity

Two implementations, one contract. This page states exactly where they agree
and where they differ.

| | **V1 — Python** | **V2 PowerShell** | **V2 bash** |
|---|---|---|---|
| Location | repository root | `v2/windows/` | `v2/unix/` |
| Runtime | Python 3.10+ | PowerShell 5.1+ | bash 3.2+ |
| Entry point | `upscayl-video.py` | `v2/windows/UpscaylVideo.ps1` | `v2/unix/upscayl-video.sh` |
| Launcher | `upscayl-video.bat` / `.sh` | `v2/windows/UpscaylVideo.bat` | `bash v2/unix/upscayl-video.sh` |
| Modules | `src/upscayl_video/` (17) | `v2/windows/modules/` (17) | `v2/unix/lib/` (16) |

The PowerShell runtime has an extra `errors` module that holds the shared
exception type; bash uses exit codes and `die` instead.

## Common behaviour

Identical in all three implementations:

- **Commands:** `doctor`, `split`, `split-all`, `upscale`, `assemble`,
  `finish`, `run`, `status`, `clean`, `model-test`.
- **Flags:** the same option names, the same meanings and the same defaults,
  including the global options `--work-dir`, `--output-dir`, `--input-dir`,
  `--config`, `--ffmpeg`, `--ffprobe`, `--max-work-gb`, `--min-free-gb`,
  `--dry-run`, `--verbose`, `--quiet`, `--yes` and `--force`.
- **Exit codes:** `0` success, `1` command failure, `2` usage error,
  `3` missing dependency, `4` invalid input or settings, `5` not enough disk
  space, `7` encode failure, `8` output validation failure, `130` interrupted.
- **The `job.txt` contract:** the same keys, the same relative `frames_dir` and
  `upscaled_dir`, the same folder layout (`batch00001/in` and `batch00001/out`,
  with the legacy `frames/`/`upscaled/` layout still accepted).
- **The `config.txt` contract:** the same keys and the same precedence
  (command line > config file > built-in default).
- **Presets and encoder selection:** `mp4-h264`, `mp4-hevc`, `mkv-hevc`,
  `mov-prores`; `auto`, `nvidia`, `amd`, `cpu` with the same fallback order.
- **Audio and subtitle rules:** the same copy/AAC/PCM/none handling, the same
  `mov_text` conversion, the same image-subtitle warning in MP4/MOV.
- **Colour handling:** BT.709 tagging after a tonemap, the same RGB fallback.
- **Chunking:** the same `--chunk-seconds auto|N` behaviour, the same resume
  markers, the same concatenation and muxing.
- **`finish --resume`:** completed jobs are skipped through
  `work/<job>/checkpoint`, and a job whose upscaled frames already cover the
  input frames is treated as done.
- **The FFmpeg argument denylist:** the same structural flags are rejected,
  including the stream-suffixed spellings (`-c:v`, `-filter:v:0`) and the alias
  spellings (`-vcodec`, `-acodec`, `-vframes`, ...).

## Platform-specific behaviour

These differences exist because the operating systems differ, not because the
implementations drifted:

| Topic | Windows | Linux/macOS |
|---|---|---|
| Paths in `job.txt` | Native (`C:\...`) | Native (`/home/...`) |
| `cygpath` conversion | not used | used under Git Bash to talk to native Windows tools |
| `--icd auto` | Finds the NVIDIA Vulkan ICD | Does not select an ICD (same as V1); use `--icd PATH` |
| GPU probe | `wmic` | not used |
| Bash availability | PowerShell 5.1+ | bash 3.2+ (no bash 4 features are used) |

Jobs are not portable between operating systems by design: `job.txt` stores
native paths.

## Known differences

| Feature | V1 | V2 PowerShell | V2 bash |
|---|---|---|---|
| `model-test` report | Full HTML report with every model | Manifest-only stub | Not implemented; the command exits `3` |
| `model-test --seed` / `--open` | yes | yes | no (command not implemented) |
| Console progress | Per-frame progress with an ETA | Batch counts | Batch counts |
| Debug output | Log file and console | Log file and console | Log file and console |
| Dependencies | Python | none beyond PowerShell | none beyond bash |

`model-test` is the only command that is not feature-complete in the V2
runtimes. Everything else in the table above is a deliberate difference in
presentation, not in behaviour.

## How parity is verified

- **Automated cross-version matrix** — `v2/tests/Run-Parity.ps1` and
  `v2/tests/Run-Parity.sh` generate media, run V1 and V2 over the same jobs and
  compare the frame counts, dimensions, durations, audio, subtitle counts and
  colour tags. The Windows matrix runs in CI on every push.
- **Shared contract tests** — each runtime has its own harness
  (`v2/tests/Test-V2.ps1`, `v2/tests/Test-V2.sh`) covering the option
  parsing, the fps handling, the colour fallback, the audio and subtitle
  plans, the chunk accounting, the colour tags and the encoder selection.
- **The version guard** — `tests/test_launchers.py` fails if the V1, V2
  PowerShell and V2 bash versions drift apart.

The recorded results are in [VALIDATION.md](VALIDATION.md).
