import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

from upscayl_video.config import load_config
from upscayl_video.errors import ValidationError
from upscayl_video.job import Job
from upscayl_video.pipeline import run_clean, run_status
from upscayl_video.util import Logger


class TestClean(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.root = Path(self.td.name)
        self.work = self.root / "work"
        self.source = self.root / "clip.mp4"
        self.source.write_bytes(b"source")
        self.job = Job.create_or_open(self.work, self.source, Logger(quiet=True))
        self.job.set("frame_count", "1")
        self.job.save()
        for name in ("frames", "upscaled", "chunks", "sequence", "output"):
            (self.job.path / name).mkdir()
            (self.job.path / name / "x").write_bytes(b"x")

    def tearDown(self):
        self.td.cleanup()

    def config(self):
        return load_config(
            None,
            overrides={
                "work_dir": str(self.work),
                "ffmpeg": sys.executable,
                "ffprobe": sys.executable,
            },
        )

    def test_all_intermediates_keeps_source_and_output(self):
        run_clean(
            [self.job], self.config(),
            frames=False, upscaled=False, chunks=False, sequence=False, batch=False,
            include_output=False, all_intermediates=True, dry_run=False,
            logger=Logger(quiet=True),
        )
        self.assertFalse((self.job.path / "frames").exists())
        self.assertFalse((self.job.path / "upscaled").exists())
        self.assertFalse((self.job.path / "chunks").exists())
        self.assertFalse((self.job.path / "sequence").exists())
        self.assertTrue((self.job.path / "output").exists())
        self.assertTrue(self.source.exists())

    def test_include_output(self):
        run_clean(
            [self.job], self.config(),
            frames=False, upscaled=False, chunks=False, sequence=False, batch=False,
            include_output=True, all_intermediates=False, dry_run=False,
            logger=Logger(quiet=True),
        )
        self.assertFalse((self.job.path / "output").exists())

    def test_dry_run_leaves_files(self):
        run_clean(
            [self.job], self.config(),
            frames=True, upscaled=False, chunks=False, sequence=False, batch=False,
            include_output=False, all_intermediates=False, dry_run=True,
            logger=Logger(quiet=True),
        )
        self.assertTrue((self.job.path / "frames").exists())

    def test_refuses_job_outside_work_dir(self):
        other_work = self.root / "other"
        other_job = Job.create_or_open(other_work, self.source, Logger(quiet=True))
        other_job.save()
        with self.assertRaises(ValidationError):
            run_clean(
                [other_job], self.config(),
                frames=True, upscaled=False, chunks=False, sequence=False, batch=False,
                include_output=False, all_intermediates=False, dry_run=True,
                logger=Logger(quiet=True),
            )


class TestStatus(unittest.TestCase):
    def test_prints_job_row(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            work = root / "work"
            source = root / "clip.mp4"
            source.write_bytes(b"source")
            job = Job.create_or_open(work, source, Logger(quiet=True))
            job.set("frame_count", "1")
            job.save()
            job.frames_dir.mkdir()
            (job.frames_dir / "frame_00000001.png").write_bytes(b"x")
            cfg = load_config(
                None,
                overrides={
                    "work_dir": str(work),
                    "ffmpeg": sys.executable,
                    "ffprobe": sys.executable,
                },
            )
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                run_status(cfg, Logger())
            output = buffer.getvalue()
            self.assertIn(job.job_id, output)
            self.assertIn("upscale", output)
            self.assertIn("1", output)


if __name__ == "__main__":
    unittest.main()
