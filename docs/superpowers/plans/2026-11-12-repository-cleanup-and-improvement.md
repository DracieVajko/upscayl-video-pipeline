# Repository Cleanup & Improvement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Upscayl Video Pipeline easy to install, understand, use and maintain — without changing the observable behavior of the V1 (Python) and V2 (PowerShell/bash) implementations.

**Architecture:** V1 stays a modular Python package (`src/upscayl_video/`). V2's two 5,000-line scripts are decomposed into the *same* 16 logical modules in both runtimes, keeping the existing entry points (`v2/windows/UpscaylVideo.ps1`, `v2/unix/upscayl-video.sh`) and their `UPSCAYL_V2_LIB=1` library-mode contract intact, so behavior and the test harnesses stay unchanged. CI runs all three runtimes on GitHub runners without a GPU.

**Tech Stack:** Python 3.10+ (unittest), PowerShell 5.1+, bash 3.2+, FFmpeg/ffprobe, GitHub Actions, ruff, PSScriptAnalyzer, ShellCheck.

**Spec:** The 13-section task brief in this session (repository cleanup & improvement). Design context: `docs/specs/2026-10-26-upscayl-video-pipeline-design.md`.

## Global Constraints

- Behavior of V1 and V2 must be preserved. Code motion only — no semantic changes during modularization.
- Public CLI surface (commands, flags, exit codes) must not change.
- `job.txt` / `config.txt` contract, presets, audio/subtitle rules and exit codes stay identical across V1, V2 PowerShell and V2 bash.
- No GPU, no downloaded models, no large media in CI. External tools are mocked or stubbed.
- `.desloppify/` stays out of Git; local state is retained.
- Never commit generated frames, upscaled output, test videos, model files, caches or machine-specific paths.
- Never claim native Linux/macOS or GPU validation that was not actually executed.
- Version is bumped once, to `0.3.4`, in one canonical place per runtime, with a CHANGELOG entry; a drift guard test enforces equality.

---

## Baseline (measured 2026-11-12, before any change)

| Suite | Command | Result |
|---|---|---|
| V1 Python | `python -m unittest discover -s tests -q` | **206 tests, OK** (144 s) |
| V2 PowerShell | `powershell -NoProfile -ExecutionPolicy Bypass -File v2/tests/Test-V2.ps1` | **71 passed, 0 failed** |
| V2 bash | `bash v2/tests/Test-V2.sh` | **70 passed, 0 failed** (unit; 85 with `RUN_V2_INTEGRATION=1`) |

Investigation findings driving this plan:

- No `.github/` directory — **zero CI workflows**.
- `v2/windows/UpscaylVideo.ps1` = 5,475 lines / 130 functions / 14 `#region` blocks.
- `v2/unix/upscayl-video.sh` = 4,968 lines / 173 functions / 16 sections.
- Both entry scripts already support library mode (`UPSCAYL_V2_LIB=1`); the test harnesses dot-source/source them directly.
- Mojibake (`â€”`, `â†'`) + UTF-8 BOM in `v2/README.md` and `docs/USAGE.md`; other Markdown is clean UTF-8.
- Versions are `0.3.3` in `src/upscayl_video/__init__.py`, `$script:V2Version` (PS1) and `UVP_VERSION` (bash); `tests/test_launchers.py` hardcodes `0.3.3`.
- `CHANGELOG.md` 0.3.3 mentions `simple-flow.sh`, which does not exist (only `simple-flow.ps1`).
- `scorecard.png` (84 KB) is committed at the repo root but not referenced by any document.
- Local tooling: Python 3.14.10, pytest 9.1.1, bash 5.3.3. **ruff, mypy, shellcheck and PSScriptAnalyzer are not installed locally** — they are provisioned by CI.

---

### Task 1: Desloppify baseline scan and triage

**Files:**
- Read: `.claude/skills/desloppify/SKILL.md`, `.desloppify/`
- Modify: files named by the scan findings

**Interfaces:**
- Consumes: the desloppify skill workflow (`next` → fix → resolve → rescan`).
- Produces: a baseline score, a triage list of real defects (not cosmetic ones), and `.desloppify/` local state that stays untracked.

- [ ] **Step 1: Load the desloppify skill and read the repository's own copy**
  Run the skill's scan procedure over the repository. Treat `v2/windows/`, `v2/unix/`, `src/` and `tests/` as separate language paths where the scanner supports it.

- [ ] **Step 2: Record the baseline score**
  Save the raw score to the plan log section below. The repo's last committed scorecard states *strict 85.0*; verify it independently.

- [ ] **Step 3: Triage findings into buckets**
  Only act on: duplicate logic, dead code, unnecessary complexity, inconsistent error handling, missing validation, unclear names, fragile path handling, cross-platform inconsistency. Skip purely cosmetic items and anything that would change behavior.

- [ ] **Step 4: Fix findings in the canonical source files**
  Apply fixes to the real module — never a `*_fixed.py` copy. Keep V1 and V2 behaviorally identical where they currently are.

- [ ] **Step 5: Re-run the three test suites** — V1 206 OK, PS1 71/0, bash 70/0 must hold.

- [ ] **Step 6: `resolve` the fixed findings and `rescan`**
  Record before/after scores.

### Task 2: CI workflows

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/psscriptanalyzer/PSScriptAnalyzerSettings.psd1`
- Modify: `tests/test_launchers.py` (version drift guard)

**Interfaces:**
- Consumes: existing test entry points — `python -m unittest discover -s tests -q`, `v2/tests/Test-V2.ps1`, `v2/tests/Test-V2.sh`, `v2/tests/Run-Parity.ps1`.
- Produces: four CI jobs — `python`, `powershell`, `bash`, `bash32-syntax`.

- [ ] **Step 1: `python` job** (ubuntu-latest): install ffmpeg (apt) so integration tests run instead of skipping; `python -m compileall -q src upscayl-video.py`; `ruff check`; `python -m unittest discover -s tests -q`.

- [ ] **Step 2: `powershell` job** (windows-latest): install ffmpeg via `setup-ffmpeg`; parse-check every `.ps1` with the PowerShell parser; run PSScriptAnalyzer with the settings file; run `v2/tests/Test-V2.ps1`; run `v2/tests/Run-Parity.ps1`.

- [ ] **Step 3: `bash` job** (ubuntu-latest): `bash -n` on every shell script; ShellCheck on the entry, modules and test scripts; run `v2/tests/Test-V2.sh` (unit, no `RUN_V2_INTEGRATION`).

- [ ] **Step 4: `bash32-syntax` job** (macos-latest): `/bin/bash -n` on the bash entry and modules to cover macOS bash 3.2.

- [ ] **Step 5: Version drift guard** — `tests/test_launchers.py` reads the version from `src/upscayl_video/__init__.py` and asserts the PS1 and bash scripts declare the same version. No hardcoded literal.

- [ ] **Step 6: Verify locally** the exact commands the workflow runs.

### Task 3: V2 modularization — PowerShell

**Files:**
- Create: `v2/windows/modules/*.ps1` (16 modules)
- Modify: `v2/windows/UpscaylVideo.ps1` (becomes the entry point)

**Interfaces:**
- Consumes: the existing function names — unchanged by this task.
- Produces: `v2/windows/UpscaylVideo.ps1` dot-sources `v2/windows/modules/*.ps1` in a fixed order, keeps `#requires -Version 5.1`, `$script:V2Version`, the `UPSCAYL_V2_LIB` guard and the `Invoke-Main`/exception bootstrap.

Module map (from the current `#region` boundaries):

| Module | Source region | Key functions |
|---|---|---|
| `core.ps1` | Logging and process helpers (36–228) | `Invoke-Child`, `Write-LogFileLine`, `Get-PipelineException` |
| `paths.ps1` | Generic file and path helpers (229–468) | `Read-KvFile`, `Resolve-AbsolutePath`, `Parse-TimeValue` |
| `config.ps1` | Configuration (469–705) | `Get-Config`, `Resolve-ToolPath` |
| `media.ps1` | Probing (706–966) | `Get-MediaInfo`, `Get-FirstFrameDimensions` |
| `jobs.ps1` | Jobs (967–1226) | `Open-Job`, `Save-Job`, `Find-OrCreateJob` |
| `frames.ps1` | Frame handling (1227–1644) + Disk estimates (1645–1729) | `Validate-FrameSet`, `Build-FrameSequence`, `Get-DiskEstimate` |
| `encode.ps1` | Encoding and muxing (1730–2384) | `Get-Presets`, `Get-EncoderCandidates`, `Build-AssembleCommand` |
| `upscayl.ps1` | Upscayl discovery and batching (2385–2799) | `Resolve-UpscaylBinary`, `Invoke-UpscaleFrames` |
| `chunking.ps1` | Chunking (2800–2874) | `Get-ChunkPlan`, `Invoke-ConcatSegments` |
| `split.ps1` | Input resolution + split (2875–3207) | `Resolve-Inputs`, `Invoke-Split` |
| `assemble.ps1` | Output paths + assemble (3619–4048) | `Resolve-OutputPath`, `Publish-AndPurge`, `Invoke-Assemble` |
| `run.ps1` | Upscale + chunked run + run-all (3209–3618) | `Invoke-Upscale`, `Invoke-ChunkedRun`, `Invoke-RunAll` |
| `admin.ps1` | split-all / finish / status / clean (4049–4333) | `Invoke-SplitAll`, `Invoke-Finish`, `Invoke-Status`, `Invoke-Clean` |
| `doctor.ps1` | Doctor (4334–4528) | `Invoke-Doctor` |
| `menu.ps1` | Menu (4529–4818) | `Invoke-Menu` |
| `cli.ps1` | Command line (4819–5456) | `Read-CommandLine`, `Invoke-Main` |

- [ ] **Step 1: Write the entry-point bootstrap** — resolve `$PSScriptRoot`, dot-source modules in dependency order, keep the library-mode guard.
- [ ] **Step 2: Move modules one at a time** (core → cli). After each move run `v2/tests/Test-V2.ps1`; it must stay 71/71.
- [ ] **Step 3: Verify the entry point** — `UpscaylVideo.bat --version`, `--help`, `doctor` and a `--dry-run` `run` behave exactly as before.
- [ ] **Step 4: Update `v2/README.md`** for the new file layout.

### Task 4: V2 modularization — bash

**Files:**
- Create: `v2/unix/lib/*.sh` (16 modules, same names as the PowerShell set)
- Modify: `v2/unix/upscayl-video.sh` (becomes the entry point)

**Interfaces:**
- Consumes: the existing `snake_case` function names — unchanged by this task.
- Produces: the entry script sources `v2/unix/lib/*.sh` in a fixed order and keeps the `UPSCAYL_V2_LIB` guard, `UVP_VERSION`, the temp-directory `EXIT` trap and `main "$@"`.

Module map follows the bash sections: `log`→`core`, `paths`+`numbers`→`paths`, `config`→`config`, `probing`→`media`, `jobs`→`jobs`, `frames`+`disk`→`frames`, `encode`→`encode`, `upscayl`→`upscayl`, `chunking`→`chunking`, `split`→`split`, `encode`(output paths)→`assemble`, `run-status-clean`→`run`/`admin`, `doctor`→`doctor`, `menu`→`menu`, `cli`→`cli`.

- [ ] **Step 1: Write the entry-point bootstrap** — resolve the script directory, source modules in dependency order, keep the library-mode guard.
- [ ] **Step 2: Move modules one at a time.** After each move run `bash v2/tests/Test-V2.sh`; it must stay 70/70.
- [ ] **Step 3: Verify with `bash -n`** on the entry and every module, and check bash 3.2 compatibility (no bash 4+ syntax).
- [ ] **Step 4: Update `v2/README.md`** for the new file layout.

### Task 5: V1 ↔ V2 parity

**Files:**
- Create: `docs/PARITY.md`
- Modify: `README.md`, `v2/README.md`

**Interfaces:**
- Consumes: the CLI surface of both implementations and the `Run-Parity` harnesses.
- Produces: a command/flag/default/difference matrix, and a parity test that asserts the three runtimes expose the same command set.

- [ ] **Step 1: Extract the command and option lists** from `src/upscayl_video/cli.py`, the PS1 option spec and the bash parser.
- [ ] **Step 2: Write `docs/PARITY.md`** — common behavior, platform-specific behavior, differing defaults, missing features (`model-test` is a manifest-only stub in both V2 runtimes), known limitations.
- [ ] **Step 3: Add a parity test** asserting the command sets match across the three implementations.

### Task 6: Documentation overhaul

**Files:**
- Modify: `README.md`, `docs/USAGE.md`, `v2/README.md`, `docs/TROUBLESHOOTING.md`, `docs/UPSTREAM.md`
- Create: `docs/PLATFORMS.md`

**Interfaces:**
- Consumes: the verified command/flag behavior from Task 5.
- Produces: valid UTF-8 Markdown with no BOM and no mojibake.

- [ ] **Step 1: Fix the encoding** in `v2/README.md` and `docs/USAGE.md` (`â€”`→`—`, `â†'`→`→`, `6â€“8`→`6–8`), strip the BOM, normalize line endings to LF.
- [ ] **Step 2: Rewrite `README.md`** — introduction, pipeline diagram, V1 vs V2, supported OS, requirements, quick start, basic example, guide links, limitations, CI badge, scorecard image.
- [ ] **Step 3: Rewrite `docs/USAGE.md`** — input requirements, installation, FFmpeg setup, Upscayl setup, frame extraction, upscaling configuration, frame reconstruction, output settings, practical commands, troubleshooting link.
- [ ] **Step 4: Create `docs/PLATFORMS.md`** — separate Windows and Linux/macOS install/run sections, honest differences.
- [ ] **Step 5: Validate every relative link** in the Markdown files resolves to an existing path.

### Task 7: Validation record

**Files:**
- Modify: `docs/VALIDATION.md`

**Interfaces:**
- Consumes: real results produced in this session and by CI.
- Produces: a validation record split into automated CI, manually executed, native platform, GPU-dependent and not-performed.

- [ ] **Step 1: Re-run every suite** and record exact counts and dates.
- [ ] **Step 2: Record the platform truth** — bash was executed on this Windows host (Git Bash / MSYS bash 5.3), **not** on native Linux/macOS; macOS bash 3.2 remains unverified except for a syntax check.
- [ ] **Step 3: Record the GPU truth** — a real Upscayl run is only claimed if actually executed.
- [ ] **Step 4: Rewrite `docs/VALIDATION.md`** with those sections and keep the record of limitations.

### Task 8: Version consistency

**Files:**
- Modify: `src/upscayl_video/__init__.py`, `v2/windows/UpscaylVideo.ps1`, `v2/unix/upscayl-video.sh`, `CHANGELOG.md`, `tests/test_launchers.py`

**Interfaces:**
- Consumes: the canonical version string.
- Produces: `0.3.4` everywhere plus a test that fails if the three drift apart.

- [ ] **Step 1: Define the canonical version** — `src/upscayl_video/__init__.py` is the source of truth; the V2 scripts must match it.
- [ ] **Step 2: Bump to `0.3.4`** in all three runtimes.
- [ ] **Step 3: Add the CHANGELOG entry** describing this maintenance release.
- [ ] **Step 4: Make `tests/test_launchers.py` version-agnostic** and assert V1 == PS1 == bash.

### Task 9: Repository cleanup

**Files:**
- Modify: `.gitignore`
- Delete: only files proven to be generated artifacts (none are currently tracked)

**Interfaces:**
- Consumes: `git status --ignored` inventory.
- Produces: a clean tree with no generated multimedia data tracked.

- [ ] **Step 1: Inventory ignored and untracked files** and classify each one.
- [ ] **Step 2: Extend `.gitignore`** for anything not covered (e.g. `v2/**/modules` caches, `*.partial.*`).
- [ ] **Step 3: Remove local caches** (`__pycache__`, `.mypy_cache`, `.ruff_cache`) — ignored by Git, safe to delete locally.
- [ ] **Step 4: Confirm nothing generated is staged.**

### Task 10: GitHub presentation

**Files:**
- Modify: `README.md` (badges, navigation)

**Interfaces:**
- Consumes: the final feature set.
- Produces: accurate repository description and topics, preserved sponsor links.

- [ ] **Step 1: Update the README badges and navigation.**
- [ ] **Step 2: Set the repository description and topics** with `gh repo edit` if the CLI is authenticated; otherwise record the exact strings for the user.
- [ ] **Step 3: Confirm sponsor settings and links are untouched** (`FUNDING.yml` / `gh api`).

### Task 11: Final verification

**Interfaces:**
- Consumes: every changed file.
- Produces: a PASS/FAIL table.

- [ ] **Step 1: Run all suites** (V1, PS1, bash unit, bash integration, parity).
- [ ] **Step 2: Run static checks** — ruff, PSScriptAnalyzer, ShellCheck, `bash -n`.
- [ ] **Step 3: Validate documentation links.**
- [ ] **Step 4: Final desloppify scan** and record the score.
- [ ] **Step 5: Inspect the complete diff** (`git diff` + `git status`) for stray artifacts.

### Task 12: Commit and push

**Interfaces:**
- Consumes: the verified working tree.
- Produces: staged commits on `main`, pushed to `origin/main`.

- [ ] **Step 1: Stage explicit paths only** — never `git add -A`.
- [ ] **Step 2: Commit** with the subject `refactor: improve pipeline maintainability, testing and documentation` plus a body listing the substantive changes.
- [ ] **Step 3: Push** to `origin/main` — no force push, no history rewrite.

### Task 13: Final report

Report V1 changes, V2 changes, modularization, parity, CI, platform results, docs, encoding fixes, desloppify before/after, unverified limitations, commit SHA and push destination.

---

## Execution log

| Date | Task | Result |
|---|---|---|
| 2026-11-12 | Investigation | Baseline recorded above; no CI; mojibake confirmed; both V2 monoliths mapped. |
