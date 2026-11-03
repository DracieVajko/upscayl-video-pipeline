"""Tests for the two-phase workspace flow."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from upscayl_video.errors import ValidationError
from upscayl_video.job import Job
from upscayl_video.util import Logger
from upscayl_video.workspace import (
    FinishOptions,
    _upscaled_count,
    _convert_layout,
    _write_manifest,
    parse_ffmpeg_args,
    run_finish,
)


class FinishDryRunTests(unittest.TestCase):
    def test_finish_options_carry_dry_run(self) -> None:
        self.assertTrue(FinishOptions(dry_run=True).dry_run)
        self.assertFalse(FinishOptions().dry_run)

    def test_dry_run_previews_without_assembling(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            job_dir = root / "work" / "clip"
            (job_dir / "batch00001" / "out").mkdir(parents=True)
            (job_dir / "batch00001" / "in").mkdir(parents=True)
            (job_dir / "batch00001" / "out" / "frame_00000001.png").write_bytes(b"x")
            (job_dir / "job.txt").write_text(
                "source=" + str(root / "clip.mp4") + "\n"
                "frames_dir=batch00001/in\n"
                "upscaled_dir=batch00001/out\n",
                encoding="utf-8",
            )
            config = SimpleNamespace(
                work_dir=root / "work",
                output_dir=root / "output",
                default_preset="mp4-h264",
                default_encoder="cpu",
            )
            logger = Logger()
            code = run_finish(config, FinishOptions(all_jobs=True, dry_run=True), logger)
            self.assertEqual(code, 0)
            self.assertFalse((root / "output").exists())


class JobLayoutTests(unittest.TestCase):
    def test_relative_overrides_resolve_against_job(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            job_dir = Path(td) / "job"
            job = Job(
                job_dir,
                {
                    "source": str(Path(td) / "clip.mp4"),
                    "frames_dir": "batch00001/in",
                    "upscaled_dir": "batch00001/out",
                },
            )
            self.assertEqual(job.frames_dir, job_dir / "batch00001" / "in")
            self.assertEqual(job.upscaled_dir, job_dir / "batch00001" / "out")

    def test_layout_conversion_moves_frames(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            job_dir = Path(td) / "job"
            (job_dir / "frames").mkdir(parents=True)
            (job_dir / "frames" / "frame_00000001.png").write_bytes(b"x")
            job = Job(job_dir, {"source": str(Path(td) / "clip.mp4")})
            _convert_layout(job, Logger(quiet=True))
            self.assertTrue((job_dir / "batch00001" / "in" / "frame_00000001.png").is_file())
            self.assertTrue((job_dir / "batch00001" / "out").is_dir())
            self.assertEqual(job.data["frames_dir"], "batch00001/in")
            self.assertEqual(job.data["upscaled_dir"], "batch00001/out")
            self.assertEqual(job.data["layout"], "batches")
            self.assertFalse((job_dir / "frames").exists())


class UpscaledCountTests(unittest.TestCase):
    def test_counts_distinct_indices(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            job_dir = Path(td) / "job"
            out = job_dir / "batch00001" / "out"
            out.mkdir(parents=True)
            (out / "frame_00000001.png").write_bytes(b"x")
            (out / "frame_00000001_dup.png").write_bytes(b"x")
            (out / "frame_00000002.png").write_bytes(b"")
            job = Job(job_dir, {"frames_dir": "batch00001/in", "upscaled_dir": "batch00001/out"})
            self.assertEqual(_upscaled_count(job), 1)

    def test_chunked_job_falls_back_to_frame_count(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            job_dir = Path(td) / "job"
            job_dir.mkdir(parents=True)
            (job_dir / ".done_chunk_0001").write_text("", encoding="utf-8")
            job = Job(job_dir, {"frame_count": "42"})
            self.assertEqual(_upscaled_count(job), 42)


class ManifestTests(unittest.TestCase):
    def test_manifest_and_readme_are_written_and_removed(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "clip.mp4"
            source.write_bytes(b"x")
            job = Job(
                root / "job",
                {
                    "source": str(source),
                    "frame_count": "10",
                    "audio_tracks": "1",
                },
            )
            config = SimpleNamespace(work_dir=root)
            _write_manifest(config, [job])
            manifest = root / "manifest.csv"
            readme = root / "README-UPScayl.txt"
            self.assertTrue(manifest.is_file())
            self.assertTrue(readme.is_file())
            self.assertIn("clip.mp4", manifest.read_text(encoding="utf-8"))
            self.assertIn("batch00001", readme.read_text(encoding="utf-8"))
            _write_manifest(config, [])
            self.assertFalse(manifest.exists())
            self.assertFalse(readme.exists())


class FfmpegArgsTests(unittest.TestCase):
    def test_accepts_encoder_tuning(self) -> None:
        self.assertEqual(
            parse_ffmpeg_args('-x264-params "keyint=48:min-keyint=48" -tune film'),
            ("-x264-params", "keyint=48:min-keyint=48", "-tune", "film"),
        )

    def test_rejects_structural_flags(self) -> None:
        for value in ("-i other.mp4", "-map 0:v", "-filter_complex x", "-y"):
            with self.assertRaises(ValidationError):
                parse_ffmpeg_args(value)

    def test_rejects_stream_suffixed_structural_flags(self) -> None:
        for value in (
            "-filter:v:0 scale=2",
            "-c:v libx265",
            "-af volume=0.5",
            "-ss 10",
            "-pix_fmt yuv420p10le",
            "-map_metadata 0",
        ):
            with self.assertRaises(ValidationError):
                parse_ffmpeg_args(value)

    def test_accepts_non_structural_flags(self) -> None:
        self.assertEqual(
            parse_ffmpeg_args("-movflags +faststart -b:v 1500k"),
            ("-movflags", "+faststart", "-b:v", "1500k"),
        )

    def test_empty_value(self) -> None:
        self.assertEqual(parse_ffmpeg_args(None), ())
        self.assertEqual(parse_ffmpeg_args("  "), ())


if __name__ == "__main__":
    unittest.main()
