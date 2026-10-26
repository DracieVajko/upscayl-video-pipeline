"""Command-line interface for the V1 core pipeline."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Sequence

from . import __version__
from .config import load_config
from .errors import PipelineError, UsageError
from .pipeline import SplitOptions, resolve_inputs, run_split
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
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command != "split":
        parser.error("unsupported command")

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
    except PipelineError as exc:
        logger.error(str(exc))
        return exc.exit_code
    except KeyboardInterrupt:
        logger.error("Interrupted")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
