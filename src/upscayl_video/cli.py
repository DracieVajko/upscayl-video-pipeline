"""Command-line interface for the V1 core pipeline."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Sequence

from . import __version__
from .config import load_config
from .doctor import run_doctor
from .encode import PRESETS, EncodeOptions
from .errors import PipelineError, UsageError, ValidationError
from .pipeline import (
    SplitOptions,
    resolve_inputs,
    resolve_jobs,
    run_assemble,
    run_clean,
    run_split,
    run_status,
)
from .util import Logger


def _global_parent() -> argparse.ArgumentParser:
    parent = argparse.ArgumentParser(add_help=False)
    parent.add_argument("--work-dir", default=argparse.SUPPRESS)
    parent.add_argument("--config", default=argparse.SUPPRESS)
    parent.add_argument("--ffmpeg", default=argparse.SUPPRESS)
    parent.add_argument("--ffprobe", default=argparse.SUPPRESS)
    parent.add_argument("--verbose", action="store_true", default=argparse.SUPPRESS)
    parent.add_argument("--quiet", action="store_true", default=argparse.SUPPRESS)
    parent.add_argument("--yes", action="store_true", default=argparse.SUPPRESS)
    parent.add_argument("--force", action="store_true", default=argparse.SUPPRESS)
    parent.add_argument("--dry-run", action="store_true", default=argparse.SUPPRESS)
    parent.add_argument(
        "--version",
        action="version",
        version=f"upscayl-video {__version__}",
    )
    return parent


def build_parser() -> argparse.ArgumentParser:
    parent = _global_parent()
    parser = argparse.ArgumentParser(
        prog="upscayl-video",
        description="Split videos into frames, upscale manually with Upscayl, and assemble them back.",
        parents=[parent],
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    split = subparsers.add_parser(
        "split",
        help="Extract frames from videos",
        parents=[parent],
    )
    split.add_argument("inputs", nargs="*", help="Video files, folders, or patterns")
    split.add_argument("--fps", default=None, help="Override frame rate (decimal or numerator/denominator)")
    split.add_argument("--start", default=None, help="Trim start (SS, MM:SS, or HH:MM:SS)")
    split.add_argument("--end", default=None, help="Trim end (SS, MM:SS, or HH:MM:SS)")
    split.add_argument("--format", choices=("png", "jpg"), default="png")
    split.add_argument("--jpeg-quality", type=int, default=1)
    split.add_argument("--png-compression", type=int, default=3)
    split.add_argument("--denoise", choices=("none", "light", "medium", "strong"), default="none")
    split.add_argument("--tonemap", action="store_true")
    split.add_argument("--decode", choices=("cpu", "gpu", "auto"), default="auto")
    split.add_argument("--scale", type=int, choices=(2, 3, 4), default=None)
    split.add_argument("--target-height", type=int, default=None)
    split.add_argument("--model", default=None)
    split.add_argument("--verify-frames", action="store_true")
    split.add_argument("--recursive", action="store_true")

    assemble = subparsers.add_parser(
        "assemble",
        help="Reassemble upscaled frames into a video",
        parents=[parent],
    )
    assemble.add_argument("jobs", nargs="*", help="Job folders, or --all")
    assemble.add_argument("--all", action="store_true", help="Assemble every job in the work directory")
    assemble.add_argument("--preset", choices=tuple(PRESETS), default=None)
    assemble.add_argument("--encoder", choices=("auto", "nvidia", "amd", "cpu"), default=None)
    assemble.add_argument("--quality", choices=("fast", "balanced", "quality"), default="balanced")
    assemble.add_argument("--crf", type=int, default=None)
    assemble.add_argument("--audio", choices=("auto", "copy", "aac", "pcm", "none"), default=None)
    assemble.add_argument("--audio-bitrate", type=int, default=192)
    assemble.add_argument("--all-audio", action="store_true")
    assemble.add_argument("--subs", choices=("auto", "copy", "convert", "none"), default=None)
    assemble.add_argument("--10bit", dest="ten_bit", action="store_true")
    assemble.add_argument("--target-height", type=int, default=None)
    assemble.add_argument("--cleanup", action="store_true")
    assemble.add_argument("--keep-chunks", action="store_true")
    assemble.add_argument("--output", default=None)
    assemble.add_argument("--upscaled-dir", default=None)
    assemble.add_argument("--pick", choices=("error", "newest", "largest"), default="error")
    assemble.add_argument("--verify-frames", action="store_true")
    assemble.add_argument("--allow-huge", action="store_true")
    assemble.add_argument("--tonemap", action="store_true", help=argparse.SUPPRESS)

    subparsers.add_parser(
        "status",
        help="Show jobs and their progress",
        parents=[parent],
    )

    clean = subparsers.add_parser(
        "clean",
        help="Delete selected intermediate directories",
        parents=[parent],
    )
    clean.add_argument("jobs", nargs="*", help="Job folders, or --all-jobs")
    clean.add_argument("--frames", action="store_true")
    clean.add_argument("--upscaled", action="store_true")
    clean.add_argument("--chunks", action="store_true")
    clean.add_argument("--batch", action="store_true")
    clean.add_argument("--all-intermediates", action="store_true")
    clean.add_argument("--include-output", action="store_true")
    clean.add_argument("--all-jobs", action="store_true")

    doctor = subparsers.add_parser(
        "doctor",
        help="Check FFmpeg, encoders, and the work directory",
        parents=[parent],
    )
    doctor.add_argument("--skip-upscayl-smoke", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    overrides: dict[str, str] = {}
    for key in ("work_dir", "ffmpeg", "ffprobe"):
        value = getattr(args, key, None)
        if value is not None:
            overrides[key] = str(value)

    logger = Logger(
        verbose=bool(getattr(args, "verbose", False)),
        quiet=bool(getattr(args, "quiet", False)),
    )
    try:
        config = load_config(
            getattr(args, "config", None),
            overrides=overrides,
            tool_dir=Path(__file__).resolve().parents[2],
        )
        if args.command == "split":
            options = SplitOptions(
                fps=args.fps,
                start=args.start,
                end=args.end,
                format=args.format,
                jpeg_quality=args.jpeg_quality,
                png_compression=args.png_compression,
                denoise=args.denoise,
                tonemap=args.tonemap,
                decode=args.decode,
                scale=args.scale,
                target_height=args.target_height,
                model=args.model or config.default_model,
                verify_frames=args.verify_frames,
                recursive=args.recursive,
                force=bool(getattr(args, "force", False)),
            )
            inputs = resolve_inputs(args.inputs, config, recursive=args.recursive)
            jobs = run_split(
                inputs,
                config,
                options,
                logger,
                dry_run=bool(getattr(args, "dry_run", False)),
                assume_yes=bool(getattr(args, "yes", False)),
            )
            if jobs:
                logger.info(f"Split complete: {len(jobs)} job(s)")
            return 0

        if args.command == "assemble":
            if args.tonemap:
                raise ValidationError(
                    "--tonemap is a split-stage option; re-split with --tonemap instead."
                )
            jobs = resolve_jobs(args.jobs, config, all_jobs=args.all)
            options = EncodeOptions(
                preset=args.preset or config.default_preset,
                encoder=args.encoder or config.default_encoder,
                quality=args.quality,
                crf=args.crf,
                audio=args.audio,
                audio_bitrate=args.audio_bitrate,
                all_audio=args.all_audio,
                subs=args.subs,
                ten_bit=args.ten_bit,
                target_height=args.target_height,
                cleanup=args.cleanup,
                output=Path(args.output) if args.output else None,
                upscaled_dir=Path(args.upscaled_dir) if args.upscaled_dir else None,
                pick=args.pick,
                verify_frames=args.verify_frames,
                allow_huge=args.allow_huge,
                force=bool(getattr(args, "force", False)),
                keep_chunks=args.keep_chunks,
            )
            outputs = run_assemble(
                jobs,
                config,
                options,
                logger,
                dry_run=bool(getattr(args, "dry_run", False)),
            )
            if outputs:
                logger.info(f"Assembled {len(outputs)} video(s)")
            return 0

        if args.command == "status":
            run_status(config, logger, verbose=bool(getattr(args, "verbose", False)))
            return 0

        if args.command == "clean":
            jobs = resolve_jobs(args.jobs, config, all_jobs=args.all_jobs)
            run_clean(
                jobs,
                config,
                frames=args.frames,
                upscaled=args.upscaled,
                chunks=args.chunks,
                sequence=False,
                batch=args.batch,
                include_output=args.include_output,
                all_intermediates=args.all_intermediates,
                dry_run=bool(getattr(args, "dry_run", False)),
                logger=logger,
            )
            return 0

        if args.command == "doctor":
            work_dir = getattr(args, "work_dir", None)
            return run_doctor(
                config,
                work_dir=Path(work_dir) if work_dir else None,
                skip_upscayl_smoke=args.skip_upscayl_smoke,
                verbose=bool(getattr(args, "verbose", False)),
                logger=logger,
            )

        parser.error("unsupported command")
        return 2
    except PipelineError as exc:
        logger.error(str(exc))
        return exc.exit_code
    except KeyboardInterrupt:
        logger.error("Interrupted")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
