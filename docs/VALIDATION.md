# Validation record — V1 and V2

Evidence from local runs on 2026-10-26/27, using the test clips present at the
time (later replaced by `Test1_Car_TrailCamera`, `Test2_Car_Drift`, and
`Test3_SecurityCamera_Dog`) plus generated fixtures.
Upscayl 2.15.0 with `upscayl-lite-4x` unless stated otherwise.

## Automated tests

```
python -m unittest discover -s tests -q
Ran 184 tests
OK
```

```
powershell -NoProfile -ExecutionPolicy Bypass -File v2/tests/Test-V2.ps1
71 passed, 0 failed
```

```
bash v2/tests/Test-V2.sh
85 passed, 0 failed   (with RUN_V2_INTEGRATION=1)
```

```
powershell -NoProfile -ExecutionPolicy Bypass -File v2/tests/Run-Parity.ps1
6 passed, 0 failed
```

```
bash v2/tests/Run-Parity.sh
28 passed, 0 failed
```

`doctor` exits `0` in V1, V2 PowerShell, and V2 bash (Git Bash); FFmpeg/ffprobe,
NVENC/AMF/CPU encoders, Upscayl models, Upscayl smoke test, and work-dir free
space pass.

## P0/P1 hardening (2026-10-27)

Targeted checks added after the first release:

- `run --dry-run` leaves the work directory unchanged in V1, PowerShell, and
  bash; no job folder or frame is created.
- `run --chunk-seconds auto` selected 60-second chunks from the disk estimate in
  V1, PowerShell, and bash, verified with real 15-frame runs.
- `cleanup=1` in `config.txt` removed intermediates after a successful `run` in
  V1 and bash.
- `assemble` finished a chunked job from its stored segments: V1 unit test,
  PowerShell real 12-second run, bash integration test.
- `--quality` together with `--crf` exits `4` in V1, PowerShell, and bash.
- `--max-work-gb` and `--min-free-gb` override the disk guard.
- The menu model picker listed four custom models next to the seven standard
  ones; `4xHFA2k` upscaled 9 frames to 640×480 with V1.
- `uhufe`: 16 HLG videos split with `--tonemap --decode auto` into 16 jobs
  (16,931 frames, 29.43 GB). HLG sources are tonemapped to BT.709, TV range.

## Cleanup and output publishing (2026-10-27)

`--cleanup` now moves the final video to `output_dir` (default `output`) and
deletes the whole `work/<job>` folder, so `work/` is empty after a successful
run. Collisions get `_1`, `_2`, ... instead of overwriting.

Verified with a 9-frame clip in V1, V2 PowerShell, and V2 bash:

- exit `0` in all three;
- the video is in `output/clip_upscaled.mp4`;
- `work/` contains no files or folders.

Full-length V1 runs assembled both example clips (`Test2_Car_Drift` 170 frames,
2160×3840, 5.717 s; `Test3_SecurityCamera_Dog` 303 frames, 1920×1440, 5.023 s),
with AAC audio and BT.709 tags. The full-length V2 runs were not completed
because the GPU was shared with other applications; the V2 9-frame run passed
on the same code path. The bash real-Upscayl run needed an explicit `--icd`
because the AMD Vulkan driver breaks device enumeration, as documented in
`TROUBLESHOOTING.md`.

## V1: full split and full assemble (no upscale)

All three clips were split with `--tonemap` and then assembled directly from
the extracted frames (`--upscaled-dir .../frames`, identity upscale).

| Clip | Duration | Frames | PNG size | Output | Output frames | Audio |
|---|---:|---:|---:|---|---:|---|
| `balenie sa na poradu.mov` | 7.531667 s | 225 | 0.4 GB | 1376×1840 H.264 | 225 | AAC 7.522 s |
| `praca2.mov` | 18.526667 s | 556 | 1.1 GB | 1552×2064 H.264 | 556 | AAC 18.508 s |
| `volanie s kolegom.mov` | 83.150000 s | 2495 | 4.7 GB | 1472×1952 H.264 | 2495 | AAC 83.105 s |

All outputs report `color_range=tv`, `color_space=bt709`,
`color_transfer=bt709`, `color_primaries=bt709`. The source clips are HLG
(`arib-std-b67`), 8-bit `yuv420p`.

## V1: real Upscayl CLI, 1-second windows

Each clip was processed with `run --start 1 --end 2 --tonemap --model
upscayl-lite-4x --scale 2 --tile 256`.

| Clip | Output size | Frames | Duration | Audio |
|---|---:|---:|---:|---|
| `balenie...` | 2752×3680 | 30 | 1.004 s | AAC 1.000 s |
| `praca2` | 3104×4128 | 30 | 0.9996 s | AAC 1.000 s |
| `volanie...` | 2944×3904 | 30 | 0.9998 s | AAC 1.003 s |

All outputs are H.264 with BT.709 tags. For `praca2`, H.264 NVENC and AMF
reject the 4128-pixel height (H.264 hardware limit), so the automatic fallback
uses `libx264`; the output is valid.

## V1: real Upscayl chunked run

`praca2.mov` (18.5 s, 556 frames) was processed with:

```bash
run "praca2.mov" --chunk-seconds 10 --tonemap \
  --model upscayl-lite-4x --scale 2 --tile 256 --batch-size 50 \
  --preset mp4-h264 --encoder auto --audio copy
```

Result: 2 chunks, 556 frames, 3104×4128, 18.526667 s, AAC 18.508 s, BT.709,
`chunks/` removed, `.done_chunk_0001` and `.done_chunk_0002` present. The
upscale took about 12 minutes on the RTX 3060 Laptop.

## V1: full 83-second chunked run

`volanie s kolegom.mov` (83.15 s, 2,495 frames) was processed end-to-end with
`--chunk-seconds 30`, the same model/settings. Result:

- 3 chunks, 2,495 output frames.
- 2944×3904 H.264, 83.116689 s.
- AAC stereo, 83.105 s, start 0.
- BT.709 primaries/transfer/matrix, TV range.
- 586.9 MB output.
- `chunks/` removed; `.done_chunk_0001`–`.done_chunk_0003` present.
- No errors in `run.log`.

## V1 fixes found during V2 parity work

The parity work exposed real V1 bugs; all are fixed and covered by tests:

- The color-tag remux now maps video/audio/subtitles/attachments explicitly and
  no longer drops subtitles or fails on MOV data tracks.
- Matroska duration probing now takes the maximum packet end and prefers packet
  counts over a fragile tail probe.
- RGB sources such as `gbr`/`bgr0` no longer pass an invalid YUV matrix to the
  encoder; they fall back to BT.709 for HD output and BT.601 (`smpte170m`) for
  SD output.
- Re-splitting a job without `--end` no longer reports a spurious settings
  difference.

## Fixes found by the fresh review

The whole-branch review (after the first green matrix) found and we fixed:

- Bash `probe_media` now copies the normalized fps into `M_FPS_*`; 25 fps
  sources assemble, resume, and chunk correctly.
- Bash chunked runs save/restore the source media state around segment/output
  probes, so later chunks keep the source width/height/fps and chapters.
- Bash `--opt=value` parsing no longer drops the following argument, and
  `--work-dir=DIR` before the command is accepted.
- Bash no longer uses `set -u`; bash 3.2 rejects empty array expansions under
  nounset, which would have broken normal assemble/split/clean paths.
- Bash uses one process-wide temp directory with an EXIT trap instead of
  leaking one file pair per child process.
- Bash converts POSIX paths for native Windows FFmpeg/Upscayl when `cygpath`
  exists, and treats an existing literal file/folder as a literal input before
  glob expansion (also fixed in V1 and V2 PowerShell).
- Bash records `last_error` in `job.txt` on stage failures and preserves the
  original exit code for `run --stop-on-error`.
- V1 and V2 PowerShell build chunk segments with the job's stored
  `target_height`, not only the value repeated on this invocation.
- `run --output FILE` with multiple inputs is rejected with exit 2 in V1, V2
  PowerShell, and bash.
- V2 PowerShell supports `--version` after a command and rejects extra
  positional arguments on `status`/`doctor`.
- The V2 PowerShell color remux uses an atomic replace.

## V2 PowerShell

- 71 unit tests pass, including contract parsing, fps, color fallback, audio
  and subtitle plans, chunk accounting, color tags, and encoder selection.
- Real Upscayl on a 0.5 s HLG window: 15 frames, 2752×3680, AAC, BT.709.
- Real `run` on a 5 s generated clip with AAC audio, `mov_text` subtitles, and
  chapters: 150 frames, 640×480, 5.000 s, AAC 4.992 s, one subtitle stream.
- Real chunked `run` on 12 s (360 frames) with `--chunk-seconds 10`: 2 chunks,
  360 frames, 12.000 s, AAC, `chunks/` removed, markers present.
- Assemble paths verified: `mp4-h264`, `mkv-hevc` (`subrip`), `mov-prores`
  (`prores`, `yuv422p10le`, `pcm_s24le`), `mp4-hevc --10bit`
  (`yuv420p10le`), target-height downscale, no-audio, odd dimensions
  (321×241 source padded to 322×242), JPEG frames, trim with audio re-encode,
  GUI-suffixed names, duplicate resolution with `--pick newest`, resume, and
  model/scale force behaviour.
- V1 ↔ V2 cross-version matrix: V1 split → V2 assemble, V2 split → V1 assemble,
  V2 → V2, V1 → V1 on MP4, MKV+MP3+SRT+chapters, and odd-dimension FFV1.
  All produced matching frame counts, dimensions, durations, audio, subtitle
  counts, and color tags.

## V2 bash

Validated on Git Bash for Windows (POSIX paths, native Windows FFmpeg/Upscayl):

- 85 tests pass (including a 25 fps integration, a failing-assemble last_error check, and a chunked fake-upscaler run with 321×241 frames, audio, and chapters).
- `doctor` green, including the Upscayl smoke test.
- Real Upscayl on a 0.5 s clip: 15 frames, 640×480.
- Real `run` on a 5 s clip with audio and `mov_text` subtitles: 150 frames,
  5.000 s, AAC, subtitle preserved.
- Real chunked `run` on 12 s with `--chunk-seconds 10`: 2 chunks, 360 frames,
  12.000 s, AAC, `chunks/` removed.
- Assemble paths verified: MP4 H.264/HEVC, MKV HEVC, MOV ProRes, JPEG frames,
  odd dimensions, trim, no-audio, target height, GUI suffixes, duplicate pick,
  resume, and clean/status/dry-run.
- `Run-Parity.sh`: bash job values and output properties match V1 (28/28).

## Cross-version notes

- Windows: V1 and V2 PowerShell share native paths and the full matrix passes.
- A V1 job can be finished by V2 PowerShell and vice versa. This was verified by
  `Run-Parity.ps1` in both directions.
- Unix: bash jobs store POSIX paths, as required by the contract (jobs are not
  portable across operating systems). Cross-version testing with a native Unix
  V1 was not possible in this environment.

## Not yet validated

- A full real-Upscayl run of the 7.5 s V1 clip (it was validated as a 1 s window
  plus a full split/assemble; the 18.5 s and 83 s clips were validated
  end-to-end).
- Full real-Upscayl runs of the 7.5/18.5/83 s clips in V2; V2 was validated on
  0.5 s, 5 s, and 12 s jobs, including chunking.
- Native Linux/macOS execution of the bash implementation and macOS bash 3.2.
  Only Git Bash on Windows and `bash -n` syntax checks were run.
- VFR Matroska duration: packet-count duration is preferred for CFR output.
  A VFR source whose container duration differs materially from frames/fps can
  still hit the output-duration tolerance; no VFR fixture is in the matrix.


