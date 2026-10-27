# Workspace, Batches, and Two-Phase Workflow — Design

- **Status:** V1 implemented; V2 follow-up
- **Date:** 2026-10-27
- **Scope:** V1 (implemented); V2 PowerShell/bash port is the remaining step
- **Related:** `docs/USAGE.md`, `docs/VALIDATION.md`, `v2/README.md`

## 1. Context

Today the pipeline is command-centric:

```
work/<job>/
  frames/
  upscaled/
  output/
```

The user splits a folder of videos, points the Upscayl GUI at `<job>/frames`,
writes to `<job>/upscaled`, then runs `assemble`. Three problems follow:

1. There is no place where the user drops originals; inputs can live anywhere
   and the job list is defined by whatever was split.
2. Final videos are buried in `work/<job>/output` instead of one clean place.
3. The Upscayl step has no stable contract (`in`/`out`), and the work folder
   keeps every intermediate forever.

The user wants two task-oriented entry points and a disposable work area:

- `split-all` — split every original in `input/` into Upscayl-ready batches,
  with defaults tuned for speed and quality on any hardware.
- `finish` — join upscaled frames into final videos, with a menu for encoder,
  quality, audio, subtitles, cleanup, and custom FFmpeg flags.
- When `finish` succeeds, `work/` is empty.

## 2. Goals

- **G1** One command splits every video in `input/`, including subfolders.
- **G2** One command finishes one, several, or all jobs.
- **G3** Frames are never duplicated: split writes directly into the batch
  input folder.
- **G4** Audio and subtitles survive the round trip.
- **G5** Defaults are fast on any hardware and safe for quality.
- **G6** V1 and V2 behave identically.
- **G7** Existing commands, jobs, and tests keep working.

## 3. Non-goals

- Automating the Upscayl GUI. `split-all` prepares folders; the user runs
  Upscayl manually. The existing automated `upscale`/`run` commands stay.
- Audio editing, normalization, or loudness matching.
- HDR output. Tonemapping produces BT.709 SDR, as today.
- Multiple batches per job in this iteration. The layout and discovery accept
  them, but `split-all` produces exactly one `batch00001`.

## 4. Layout

```
<workspace>/
  input/                     originals; written by the user, never modified
  work/                      disposable; empty after a successful finish
    <job>/
      job.txt                same contract as today, plus layout fields
      audio/
        track01.mka          lossless stream copy, one file per source track
        info.txt             codec, language, title, channels, sample rate
      batch00001/
        in/                  split frames; Upscayl input
        out/                 Upscayl output
      logs/
  output/                    final videos; nothing else
```

Rules:

- `input/` is never written or deleted by the pipeline.
- `work/` is disposable. Any file in it can be removed without data loss
  once the corresponding output exists.
- `output/` contains only final deliverables.
- `work/manifest.csv` and `work/README-UPScayl.txt` are written by
  `split-all` for convenience and removed when `work/` is cleaned.
- The batch folder is created with both `in/` and `out/` so the Upscayl GUI
  can be pointed at it immediately.

## 5. Workspace resolution

New config keys, all optional:

| Key | Default | Meaning |
|---|---|---|
| `workspace` | `.` | root that contains the three folders |
| `input_dir` | `input` | originals, relative to workspace or absolute |
| `work_dir` | `work` | existing key, reused |
| `output_dir` | `output` | finals, relative to workspace or absolute |

The workspace itself resolves like other config paths: an explicit
`--workspace` is taken from the working directory, a config value from the
config directory. The three directories are then resolved against the
workspace unless they are absolute.

`split-all` and `finish` create missing directories. Legacy commands keep
using `work_dir` alone.

## 6. `split-all`

Entry points:

- `split-all.bat` (Windows) and `split-all.sh` (Unix) in the repository root,
  thin launchers for the V1 Python engine.
- V2: `UpscaylVideo.bat split-all` and `upscayl-video.sh split-all`.

CLI:

```
upscayl-video split-all [--workspace PATH] [--format png|jpg]
                        [--png-compression N] [--jpeg-quality N]
                        [--denoise none|light|medium|strong]
                        [--decode auto|cpu|gpu] [--tonemap|--no-tonemap]
                        [--dry-run] [--yes]
```

Behaviour:

1. Resolve the workspace and scan `input_dir` recursively for media files
   (`.mp4`, `.mov`, `.mkv`, `.avi`, `.webm`, `.m4v`, `.mts`, `.m2ts`).
2. Fail with exit 2 if `input_dir` is missing or contains no video.
3. For each source, create or reopen the job (`Job.create_or_open`), probe it,
   and estimate frame count and disk usage with the existing sampling
   estimator. Existing jobs with a matching source and a completed split are
   skipped and reported as `skip`.
4. Preflight disk, excluding skipped jobs: if the total estimate plus the
   `min_free_gb` reserve exceeds the free space on the work volume, abort
   before writing anything, print a per-job table, and suggest `--format jpg`
   or freeing space. Otherwise print the plan and ask `Continue? [y/N]`
   unless `--yes` is set.
5. Split each job with the fast profile:

| Knob | Default | Reason |
|---|---|---|
| frame format | PNG | lossless; Upscayl amplifies JPEG artifacts |
| PNG compression | 1 | much faster writes than level 3, slightly larger |
| denoise | none | costs time and destroys detail |
| decode | auto | per-job GPU/CPU benchmark, faster wins |
| frame rate | source | existing VFR/CFR handling |
| Upscayl scale (stored in `job.txt`) | 2 | 4x output risks >40 MP frames and disk exhaustion |
| audio | stream copy | lossless, negligible size |

6. Auto-tonemap: when `color_transfer` is `arib-std-b67` or `smpte2084`, apply
   the existing tonemap path to BT.709. `--no-tonemap` disables it;
   `--tonemap` forces it. SDR sources are untouched.
7. Extract every audio track into `work/<job>/audio/trackNN.mka` with
   `-c copy`, honouring the job's stored split range (always the full length
   for `split-all`). If copy fails, retry the track with FLAC. Write
   `audio/info.txt`. Sources without audio get an empty folder and
   `audio_tracks=0` in `job.txt`.
8. Create `batch00001/in` and `batch00001/out`, write `frames_dir` and
   `upscaled_dir` into `job.txt`, and write the split marker.
9. Write `work/manifest.csv` and `work/README-UPScayl.txt` with the per-job
   `in`/`out` paths and the recommended Upscayl settings.
10. Print a summary table: job, source, frames, size, input path, output path.

`--dry-run` performs probing and estimates, prints the plan, and creates
nothing.

## 7. `finish`

Entry points:

- `finish.bat` and `finish.sh` in the repository root, thin launchers for V1.
- V2: `UpscaylVideo.bat finish` and `upscayl-video.sh finish`.

CLI:

```
upscayl-video finish [--workspace PATH] [--job NAME] [--all]
                     [--profile default|fast|quality]
                     [--preset NAME] [--encoder auto|nvidia|amd|cpu]
                     [--quality fast|balanced|quality] [--crf N]
                     [--audio auto|copy|aac|pcm|none] [--audio-bitrate N]
                     [--all-audio] [--subs auto|copy|convert|none]
                     [--10bit] [--ffmpeg-args "..."]
                     [--keep] [--force] [--yes] [--verify-frames]
```

Interactive mode (no `--job`/`--all`) lists jobs with
`upscaled/expected` counts and asks for one job or `a` for all. Jobs with no
upscaled frames are shown as `not upscaled` and cannot be assembled. In
`--all` mode they are skipped with a warning and do not fail the run.

Profiles:

| Profile | Preset | Encoder | Quality | Audio | Subs |
|---|---|---|---|---|---|
| `default` | config `default_preset` (mp4-h264) | config | balanced (CRF 20 H.264) | auto | auto |
| `fast` | mp4-h264 | auto; NVENC/AMF when present | fast (CRF 22) | auto | auto |
| `quality` | mp4-hevc | auto | quality (CRF 20 HEVC) | auto | auto |

`default` honours the configured defaults so an existing `config.txt` keeps
its meaning. The interactive menu offers these three plus `Custom`, which
asks for every flag listed in the CLI form.

### Custom FFmpeg arguments

- Accepted from the menu, `--ffmpeg-args`, or config `ffmpeg_args`.
- Appended immediately before the output path, so later flags override the
  pipeline's own defaults (for example `-x264-params`, `-tune`, `-profile:v`,
  `-movflags +faststart`).
- Rejected with exit 4: `-i`, `-map`, `-filter_complex`, `-lavfi`, `-vf`,
  `-filter:v`, `-y`, `-n`, `-f`. These change input/output structure or
  could truncate files.
- Tokens are split with `shlex`; quoting errors produce a clear message.
- On encode failure, `--verbose` prints the fully expanded command.

### Output

- Written to `output_dir/<source_stem>_upscaled.<ext>`.
- If the path exists and `--force` is not set, a numeric suffix is added and
  a warning is printed; no silent overwrite.
- If a job has multiple batches (created by a future split), they are merged
  in numeric order; frame numbering must be continuous or the job fails
  validation.

### Verification

Before cleanup, `finish` checks:

- upscaled frame count equals the expected count;
- output duration matches the source within one frame;
- the muxed audio track count matches what was requested: one by default,
  every source track with `--all-audio`, none with `--audio none`;
- dimensions equal source dimensions times the scale (or the target height);
- color tags are BT.709 for tonemapped jobs;
- container extension matches the preset.

`--verify-frames` additionally validates the image signature of every
selected frame, as the existing assembler does.

### Cleanup

- On success the entire `work/<job>` directory is deleted: frames, batches,
  audio, chunks, logs, `job.txt`.
- `--keep` disables cleanup for that run.
- Cleanup runs per job. A failed job keeps its work directory and the error
  is reported; successful jobs are still cleaned.
- When no jobs remain, `work/manifest.csv` and `work/README-UPScayl.txt` are
  removed, leaving an empty `work/`.
- `input/` is never touched.

## 8. Job contract changes

`job.txt` gains optional fields:

| Field | Example | Meaning |
|---|---|---|
| `layout` | `batches` | absent means legacy layout |
| `frames_dir` | `batch00001/in` | resolved relative to the job folder |
| `upscaled_dir` | `batch00001/out` | existing key, now resolved relative to the job folder |
| `audio_tracks` | `2` | number of extracted tracks |

`Job.frames_dir` and `Job.upscaled_dir` resolve a stored relative path
against the job folder. An empty or missing value keeps the legacy
`frames`/`upscaled` names, so old jobs continue to work unchanged.

`Job.audio_dir` is always `<job>/audio` and is not stored.

`assemble` and `finish` prefer extracted audio when `audio/` contains one
track per source audio stream, and fall back to the source file otherwise
(partial extraction is not trusted). Stream language and title are restored
from `audio/info.txt`.

## 9. Config additions

```ini
workspace=.
input_dir=input
output_dir=output
auto_tonemap=1
split_format=png
split_png_compression=1
finish_profile=default
ffmpeg_args=
```

All are optional; defaults preserve current behaviour for the legacy
commands. Only `split-all` and `finish` read the new keys, and `ffmpeg_args`
applies to `finish` only.

## 10. Error handling

| Situation | Behaviour |
|---|---|
| `input_dir` missing or empty | exit 2, message names the expected path |
| disk estimate does not fit | abort before writing, print table and options |
| split of one job fails | keep prior jobs, report, continue with the next, exit non-zero at the end |
| Upscayl wrote into a model subfolder | recursive scan, already supported |
| duplicate frame indexes | existing `--pick` handling, error by default |
| job has no upscaled frames | listed, refused with a clear message |
| upscaled count mismatch | fail before encode, keep work dir |
| output exists | suffix + warning unless `--force` |
| blocked custom flag | exit 4 before encoding |
| source moved or changed | existing mtime/size check, clear error |
| job with chunks | delegated to the existing chunked assemble path |

## 11. Compatibility and migration

- `split`, `upscale`, `assemble`, `run`, `status`, `clean`, `doctor`, and the
  nine-option menu keep their current behaviour and flags.
- Legacy jobs (`frames/`, `upscaled/`) are discovered and assembled as today.
- The new layout is produced only by `split-all`.
- `uhufe`: nothing is upscaled yet, so the existing 16 job folders are deleted
  and re-split with `split-all` after implementation. The originals stay on
  the Desktop and that folder is used as `input_dir` for this workspace; they
  are not copied.

## 12. Testing strategy

1. **Unit (V1):** path resolution, job contract fallbacks, batch discovery,
   custom-flag validation, audio trim metadata, cleanup rules.
2. **Integration (V1):** split a 0.3 s clip with an audio track into
   `batch00001/in`, verify `audio/`, copy frames into `out`, run `finish`,
   verify output and that the job folder is gone.
3. **Real data:** `TEST_EXAMPLE_VIDEOS` (3 clips) and the `uhufe` set
   (16 HDR videos) for `split-all`; one job upscaled by hand in Upscayl to
   validate the real GUI path.
4. **V2 parity:** the same integration scenarios in PowerShell and bash; the
   existing `Test-V2.ps1` and `Test-V2.sh` suites gain `split-all` and
   `finish` cases.
5. **Regression:** full V1, PowerShell, and bash suites must pass; the
   existing counts are 181 / 71 / 85 before this change.

### Acceptance criteria

- `split-all` on `TEST_EXAMPLE_VIDEOS` produces one job per file, each with
  `audio/`, `batch00001/in`, `batch00001/out`, and a correct `job.txt`.
- No frame exists twice anywhere in the workspace.
- `finish --all` produces one video per job in `output/`, prefers extracted
  audio, and leaves `work/` empty.
- `--keep` leaves the work directories intact.
- Legacy jobs still assemble.
- V1, PowerShell, and bash suites pass.

## 13. Order of work

1. V1 engine: job contract, workspace config, `split-all`, `finish`.
2. V1 tests and a real run on the test videos.
3. V2 PowerShell and bash parity plus tests.
4. `uhufe` re-split and real Upscayl validation on one job.
5. Documentation: `README`, `USAGE`, `VALIDATION`, `CHANGELOG`, `v2/README`.

## 14. Assumptions

- `TEST_EXAMPLE_VIDEOS` holds the current three test clips (`Test1_Car_TrailCamera`,
  `Test2_Car_Drift`, `Test3_SecurityCamera_Dog`); acceptance uses those plus
  the `uhufe` set.
- Upscayl accepts a folder of images and writes to a chosen output folder;
  no CLI changes are needed for the manual flow.
- Windows is the primary platform; Unix support is validated on Git Bash and
  syntax-checked for bash 3.2.
