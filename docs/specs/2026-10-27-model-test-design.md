# Model Test — Design

- **Status:** approved
- **Date:** 2026-10-27
- **Scope:** V1 (implemented); V2 PowerShell/bash is a follow-up
- **Related:** `docs/USAGE.md`, `docs/VALIDATION.md`

## 1. Context

The pipeline exposes 11 models (standard Upscayl plus custom ones). Choosing a
model for a given video is guesswork: a model that preserves faces can over-sharpen
text, and the best choice depends on the source. Users need a quick, per-video
comparison without running the whole pipeline.

## 2. Goals

- Pick a small number of frames spread across the clip.
- Upscale each frame with every available model.
- Produce a visual report that lets the user choose a model.
- Keep it out of the normal `run`/menu flow: a separate CLI command.

## 3. Non-goals

- Automatic model selection or quality scoring. Without a reference image,
  PSNR/SSIM would be misleading.
- Full-video processing. The test is a sample, not a render.
- Replacing the existing `upscale` command or the menu.

## 4. Command

```
upscayl-video model-test <video> [options]
```

Options:

| Flag | Default | Meaning |
|---|---|---|
| `--frames N` | `3` | number of sampled frames |
| `--seed N` | random | reproducible selection; the seed is printed |
| `--scale 2\|3\|4` | config `default_scale` | Upscayl output scale |
| `--model NAME` | all | repeatable; restrict the model set |
| `--models-dir DIR` | config | extra models directory |
| `--tile auto\|N` | config | Upscayl tile |
| `--gpu N` | config | Vulkan device |
| `--icd auto\|none\|PATH` | config | Vulkan ICD |
| `--decode cpu\|gpu\|auto` | `cpu` | frame extraction |
| `--tonemap` / `--no-tonemap` | auto | HDR handling |
| `--work-dir DIR` | config | where `_model_tests` is created |
| `--open` | off | open the HTML report |
| `--dry-run` | off | print the plan; extract nothing |
| `--yes` | off | skip the long-run confirmation |

## 5. Frame sampling

Divide the duration into `N` equal segments. In each segment pick a uniform
random point inside the middle 80 % (10 % margin at both ends). Sort the points
and require a minimum distance of `duration / (N * 4)`; resample if needed.

`--seed` makes the selection reproducible. Without it, a random 31-bit seed is
generated and printed, so a run can be repeated.

Extraction reuses the split filter chain:

- HDR (`arib-std-b67`, `smpte2084`) is tonemapped to BT.709 by default; `--no-tonemap`
  is rejected for HDR, matching `split`.
- PNG, 8-bit RGB, PNG compression level 1 (fast).
- One frame per timestamp, written as `frame_%08d.png`.
- `--decode cpu` by default because three frames do not justify a benchmark.

## 6. Model discovery

Union of:

1. the configured `models_dir`;
2. the models directory next to `upscayl-bin` (`resources/models`);
3. `--models-dir` when given.

Models are `.param`/`.bin` pairs; duplicates are removed by name, with the
configured directory winning. `--model` keeps only the named models and fails
with exit 4 if a name is unknown.

Each model runs with its own `-m <directory>` so custom and standard models can
be mixed.

## 7. Upscayl invocation

```
upscayl-bin -i <test>/original -o <test>/<model> \
            -m <model-dir> -n <model> -s <scale> -g <gpu> \
            -t <tile> -f png -c 0
```

The ICD environment is applied when configured. A failing model is recorded in
the report and the test continues; if every model fails, exit 6.

## 8. Output layout

```
work/_model_tests/<video>/<YYYYMMDD-HHMMSS>/
  original/frame_00000001.png ...
  upscayl-standard-4x/frame_00000001.png ...
  remacri-4x/...
  4xHFA2k/...
  report.html
  test.txt
```

`_model_tests` has no `job.txt`, so `find_jobs`, `status`, and `clean` ignore it.
The folder is kept for inspection; the user deletes it when done.

## 9. Report

`report.html` is self-contained apart from relative image links:

- one section per sampled frame, showing the timestamp;
- a card per model: thumbnail, model name, file size, link to the full PNG;
- the original frame first for reference;
- a neutral dark background, no quality ranking;
- a note that higher file size does not mean a better model;
- failures shown as an error card.

`test.txt` lists the video, seed, timestamps, models, and result paths for
scripting.

## 10. Error handling

| Situation | Behaviour |
|---|---|
| no models found | exit 3 with the searched directories |
| unknown `--model` | exit 4 |
| HDR without tonemap | exit 4, same message as `split` |
| one model fails | record, continue |
| all models fail | exit 6 |
| `--dry-run` | print timestamps/models/runs; write nothing |
| report cannot be written | exit 7, keep the images |

## 11. V1/V2 parity

V1 is implemented in this iteration. The V2 PowerShell and bash ports are a
follow-up; they will use the same command, flags, layout, and report template.
Until then, `model-test` is documented as V1-only.

## 12. Testing

1. Unit: seeded sampling (deterministic, distinct, spread), model union and
   duplicate removal, report content, unknown model.
2. Integration: generated 5 s clip, fake `upscayl-bin` that copies frames,
   two models; assert 3 originals, 6 outputs, report, and `test.txt`.
3. Real: `Test3_SecurityCamera_Dog` with all 11 models and 3 frames; open the
   report.
4. V2: the same integration in PowerShell and bash.

### Acceptance criteria

- `model-test` on a clip produces `frames × models` upscaled images and a report.
- The same `--seed` reproduces the timestamps.
- `--model` restricts the run.
- HDR auto-tonemaps.
- Normal `run`, `split`, `assemble`, and the menu are unchanged.
