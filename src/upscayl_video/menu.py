"""Small interactive menu for the core pipeline."""

from __future__ import annotations

from pathlib import Path

from .config import Config
from .doctor import run_doctor
from .encode import PRESETS, EncodeOptions
from .errors import PipelineError
from .probe import probe_media
from .upscayl import discover_upscayl, list_models
from .pipeline import (
    find_jobs,
    RunOptions,
    SplitOptions,
    UpscaleOptions,
    resolve_inputs,
    resolve_jobs,
    run_all,
    run_assemble,
    run_clean,
    run_split,
    run_status,
    run_upscale,
)
from .util import Logger


def _ask(label: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    value = input(f"{label}{suffix}: ").strip()
    return value or default


def _catch(logger: Logger, action) -> None:
    try:
        action()
    except PipelineError as exc:
        print(str(exc))


_MODEL_HINTS = {
    "upscayl-standard-4x": "general-purpose default",
    "upscayl-lite-4x": "fastest, good for long videos",
    "remacri-4x": "live-action detail",
    "ultramix-balanced-4x": "balanced live-action",
    "ultrasharp-4x": "sharp; may over-sharpen compressed sources",
    "high-fidelity-4x": "conservative, less hallucination",
    "digital-art-4x": "anime and illustrations",
}


def _select_model(config: Config, logger: Logger) -> tuple[str, str | None]:
    choices: list[tuple[str, str]] = []
    seen: set[str] = set()

    def add_directory(directory) -> None:
        if directory is None:
            return
        try:
            models = list_models(directory)
        except PipelineError:
            return
        for model in models:
            if model.name not in seen:
                seen.add(model.name)
                choices.append((model.name, str(directory)))

    try:
        paths = discover_upscayl(config)
        add_directory(paths.models_dir)
        standard = paths.binary.parent.parent / "models"
        if standard.is_dir():
            add_directory(standard)
    except PipelineError:
        pass
    if config.models_dir is not None:
        add_directory(config.models_dir)
    if config.upscayl_bin is not None:
        add_directory(config.upscayl_bin.parent.parent / "models")

    if not choices:
        return _ask("Model", config.default_model), None

    print("Models:")
    for index, (name, directory) in enumerate(choices, 1):
        hint = _MODEL_HINTS.get(name, "custom")
        print(f"  {index}) {name} - {hint}")
        print(f"     {directory}")
    names = {name for name, _ in choices}
    default_name = config.default_model if config.default_model in names else choices[0][0]
    answer = _ask("Model number or name", default_name)
    if answer.isdigit():
        index = int(answer)
        if 1 <= index <= len(choices):
            return choices[index - 1]
    for name, directory in choices:
        if answer.lower() == name.lower():
            return name, directory
    return answer, None


def _select_jobs(config: Config, logger: Logger) -> list:
    target = _ask("Job folder or work dir")
    if not target:
        return []
    path = Path(target).expanduser().resolve()
    if (path / "job.txt").is_file():
        return resolve_jobs([str(path)], config, all_jobs=False)
    jobs = find_jobs(path)
    if not jobs:
        print(f"No jobs found in: {path}")
        return []
    print("Jobs:")
    for index, job in enumerate(jobs, 1):
        print(f"  {index}) {job.job_id} <- {job.source_path}")
    answer = _ask("Job number or 'a' for all", "a").lower()
    if answer in {"a", "all"}:
        return jobs
    if answer.isdigit():
        index = int(answer)
        if 1 <= index <= len(jobs):
            return [jobs[index - 1]]
    print("Invalid job selection.")
    return []


def run_menu(config: Config | None, logger: Logger) -> int:
    while True:
        print()
        print("Upscayl Video Pipeline")
        print("1) Run all (split + upscale + assemble)")
        print("2) Split video(s)")
        print("3) Upscale a job")
        print("4) Assemble a job")
        print("5) Status")
        print("6) Doctor")
        print("7) Clean a job")
        print("8) Settings")
        print("9) Exit")
        try:
            choice = input("Choose [9]: ").strip() or "9"
        except EOFError:
            return 0
        except KeyboardInterrupt:
            print()
            return 130

        if choice in {"9", "q", "quit", "exit"}:
            return 0
        if choice not in {"1", "2", "3", "4", "5", "6", "7", "8"}:
            print("Invalid choice.")
            continue
        if config is None:
            print("Configuration is not loaded.")
            continue

        if choice == "1":
            def action() -> None:
                target = _ask("Video file or folder")
                if not target:
                    return
                inputs = resolve_inputs([target], config, recursive=False)
                try:
                    first_media = probe_media(config.ffprobe, inputs[0], logger)
                except PipelineError as exc:
                    print(str(exc))
                    return
                tonemap = False
                if first_media.hdr:
                    answer = _ask(
                        "HDR source detected; tonemap to SDR BT.709? y/N", "n"
                    ).lower()
                    if answer not in {"y", "yes"}:
                        print("Aborted: HDR requires --tonemap.")
                        return
                    tonemap = True
                model, model_dir = _select_model(config, logger)
                preset = _ask("Preset " + "/".join(sorted(PRESETS)), config.default_preset)
                if preset not in PRESETS:
                    print("Unknown preset.")
                    return
                audio = _ask("Audio auto/copy/aac/pcm/none", "auto")
                subs = _ask("Subtitles auto/copy/convert/none", "auto")
                cleanup = _ask("Delete intermediates after success? y/N", "y" if config.cleanup else "n").lower() in {"y", "yes"}
                scale = config.default_scale
                split = SplitOptions(
                    fps=None, start=None, end=None, format="png",
                    jpeg_quality=1, png_compression=3, denoise="none",
                    tonemap=tonemap, decode="auto", scale=scale,
                    target_height=None, model=model, verify_frames=False,
                    recursive=False, force=False,
                )
                upscale = UpscaleOptions(
                    model=model,
                    scale=scale,
                    models_dir=Path(model_dir) if model_dir else None,
                    assume_yes=False,
                )
                encode = EncodeOptions(
                    preset=preset,
                    encoder=config.default_encoder,
                    audio=None if audio == "auto" else audio,
                    subs=None if subs == "auto" else subs,
                    cleanup=cleanup,
                )
                inputs = resolve_inputs([target], config, recursive=False)
                run_all(
                    inputs,
                    config,
                    RunOptions(
                        split=split,
                        upscale=upscale,
                        encode=encode,
                        cleanup=cleanup,
                        chunk_seconds="auto",
                    ),
                    logger,
                )

            _catch(logger, action)
        elif choice == "2":
            def action() -> None:
                target = _ask("Video file or folder")
                if not target:
                    return
                fmt = _ask("Frame format png/jpg", "png")
                if fmt not in {"png", "jpg"}:
                    print("Frame format must be png or jpg.")
                    return
                scale_text = _ask("Scale 2/3/4", str(config.default_scale))
                try:
                    scale = int(scale_text)
                except ValueError:
                    print("Scale must be 2, 3, or 4.")
                    return
                if scale not in {2, 3, 4}:
                    print("Scale must be 2, 3, or 4.")
                    return
                options = SplitOptions(
                    fps=None, start=None, end=None, format=fmt,
                    jpeg_quality=1, png_compression=3, denoise="none",
                    tonemap=False, decode="auto", scale=scale,
                    target_height=None, model=config.default_model,
                    verify_frames=False, recursive=False, force=False,
                )
                inputs = resolve_inputs([target], config, recursive=False)
                run_split(inputs, config, options, logger)

            _catch(logger, action)
        elif choice == "3":
            def action() -> None:
                jobs = _select_jobs(config, logger)
                if not jobs:
                    return
                model, model_dir = _select_model(config, logger)
                scale_text = _ask("Scale 2/3/4", str(config.default_scale))
                try:
                    scale = int(scale_text)
                except ValueError:
                    print("Scale must be 2, 3, or 4.")
                    return
                print(
                    "Note: upscale writes frames only; audio and subtitles "
                    "are muxed by Assemble or Run all."
                )
                run_upscale(
                    jobs,
                    config,
                    UpscaleOptions(
                        model=model,
                        scale=scale,
                        models_dir=Path(model_dir) if model_dir else None,
                        assume_yes=False,
                    ),
                    logger,
                )

            _catch(logger, action)
        elif choice == "4":
            def action() -> None:
                jobs = _select_jobs(config, logger)
                if not jobs:
                    return
                preset = _ask("Preset " + "/".join(sorted(PRESETS)), config.default_preset)
                if preset not in PRESETS:
                    print("Unknown preset.")
                    return
                encoder = _ask("Encoder auto/nvidia/amd/cpu", config.default_encoder)
                if encoder not in {"auto", "nvidia", "amd", "cpu"}:
                    print("Unknown encoder.")
                    return
                audio = _ask("Audio auto/copy/aac/pcm/none", "auto")
                subs = _ask("Subtitles auto/copy/convert/none", "auto")
                options = EncodeOptions(
                    preset=preset,
                    encoder=encoder,
                    audio=None if audio == "auto" else audio,
                    subs=None if subs == "auto" else subs,
                )
                run_assemble(jobs, config, options, logger)

            _catch(logger, action)
        elif choice == "5":
            run_status(config, logger)
        elif choice == "6":
            run_doctor(
                config,
                work_dir=None,
                skip_upscayl_smoke=True,
                verbose=False,
                logger=logger,
            )
        elif choice == "7":
            def action() -> None:
                job_path = _ask("Job folder")
                if not job_path:
                    return
                answer = input(
                    "Delete all intermediate frames for this job? [y/N] "
                ).strip().lower()
                if answer not in {"y", "yes"}:
                    print("Cancelled.")
                    return
                jobs = resolve_jobs([job_path], config, all_jobs=False)
                run_clean(
                    jobs,
                    config,
                    frames=False,
                    upscaled=False,
                    chunks=False,
                    sequence=False,
                    batch=False,
                    include_output=False,
                    all_intermediates=True,
                    dry_run=False,
                    logger=logger,
                )

            _catch(logger, action)
        elif choice == "8":
            print(f"Config: {config.config_path}")
            print(f"FFmpeg: {config.ffmpeg}")
            print(f"Upscayl: {config.upscayl_bin or 'auto'}")
            print(f"Models: {config.models_dir or 'auto'}")
            print(f"Work dir: {config.work_dir}")
            print(f"Model/scale/preset: {config.default_model} / {config.default_scale} / {config.default_preset}")
            print(f"Chunking/cleanup: auto / {config.cleanup}")
