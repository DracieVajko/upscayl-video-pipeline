# V2 — native implementation (planned)

V2 is not implemented yet.

It will provide the same commands, flags, folder layout, and `job.txt` contract
as V1, without Python:

- `v2/windows/` — PowerShell 5.1+ and a `.bat` launcher.
- `v2/unix/` — bash 3.2+.

The full design is in
[`docs/specs/2026-10-26-upscayl-video-pipeline-design.md`](../docs/specs/2026-10-26-upscayl-video-pipeline-design.md).
V1 currently lives at the repository root; V2 will be added here so users can
choose the implementation that fits their machine.

Nothing in this folder should be treated as working software yet.
