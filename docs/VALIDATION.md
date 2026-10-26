# Validation record — V1

Evidence from a local run on 2026-10-26, using the three files in
`TEST_EXAMPLE_VIDEOS/` (not committed) and Upscayl 2.15.0 with
`upscayl-lite-4x`.

## Automated tests

```
python -m unittest discover -s tests -q
Ran 170 tests
OK
```

`doctor` exits `0`; FFmpeg/ffprobe, NVENC/AMF/CPU encoders, Upscayl models,
Upscayl smoke test, and work-dir free space pass.

## Full split and full assemble (no upscale)

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

## Real Upscayl CLI, 1-second windows

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

## Real Upscayl chunked run

`praca2.mov` (18.5 s, 556 frames) was processed with:

```bash
run "praca2.mov" --chunk-seconds 10 --tonemap \
  --model upscayl-lite-4x --scale 2 --tile 256 --batch-size 50 \
  --preset mp4-h264 --encoder auto --audio copy
```

Result: 2 chunks, 556 frames, 3104×4128, 18.526667 s, AAC 18.508 s, BT.709,
`chunks/` removed, `.done_chunk_0001` and `.done_chunk_0002` present. The
upscale took about 12 minutes on the RTX 3060 Laptop.

## Full 83-second chunked run

`volanie s kolegom.mov` (83.15 s, 2,495 frames) was processed end-to-end with
`--chunk-seconds 30`, the same model/settings. Result:

- 3 chunks, 2,495 output frames.
- 2944×3904 H.264, 83.116689 s.
- AAC stereo, 83.105 s, start 0.
- BT.709 primaries/transfer/matrix, TV range.
- 586.9 MB output.
- `chunks/` removed; `.done_chunk_0001`–`.done_chunk_0003` present.
- No errors in `run.log`.

## Not yet validated

- `run --chunk-seconds auto`; this build uses the non-chunked path for `auto`.
  Use an explicit value such as `60`.
- V2 PowerShell/bash parity.
- A full real-Upscayl run of the 7.5 s clip (it was validated as a 1 s window
  plus a full split/assemble; the 18.5 s and 83 s clips were validated
  end-to-end).
