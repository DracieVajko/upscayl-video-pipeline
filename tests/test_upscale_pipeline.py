import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.config import load_config
from upscayl_video.job import Job
from upscayl_video.pipeline import UpscaleOptions, run_upscale
from upscayl_video.util import Logger


class TestUpscalePipeline(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.root = Path(self.td.name)
        self.binary = self.root / ("upscayl-bin.exe" if sys.platform.startswith("win") else "upscayl-bin")
        self.binary.write_bytes(b"")
        self.models = self.root / "models"
        self.models.mkdir()
        (self.models / "m.param").write_text("x", encoding="utf-8")
        (self.models / "m.bin").write_bytes(b"x")
        self.source = self.root / "source.mp4"
        self.source.write_bytes(b"x")
        self.job = Job.create_or_open(self.root / "work", self.source, Logger(quiet=True))
        self.job.set("frame_count", "2")
        self.job.frames_dir.mkdir()
        for i in (1, 2):
            (self.job.frames_dir / f"frame_{i:08d}.png").write_bytes(b"x")
        self.job.save()
        self.cfg = load_config(None, overrides={
            "ffmpeg": sys.executable,
            "ffprobe": sys.executable,
            "work_dir": str(self.root / "work"),
            "upscayl_bin": str(self.binary),
            "models_dir": str(self.models),
        })

    def tearDown(self):
        self.td.cleanup()

    @patch("upscayl_video.pipeline.upscale_frames", return_value=2)
    def test_upscale_updates_job(self, upscale):
        jobs = run_upscale(
            [self.job],
            self.cfg,
            UpscaleOptions(model="m", scale=2, tile="128", batch_size=2),
            Logger(quiet=True),
        )
        self.assertEqual(jobs[0].get("model"), "m")
        self.assertEqual(jobs[0].get_int("upscaled_count"), 2)
        self.assertTrue(jobs[0].is_done("upscale"))
        upscale.assert_called_once()

    def test_missing_model_is_rejected(self):
        with self.assertRaises(Exception):
            run_upscale(
                [self.job],
                self.cfg,
                UpscaleOptions(model="nope", scale=2),
                Logger(quiet=True),
            )


if __name__ == "__main__":
    unittest.main()
