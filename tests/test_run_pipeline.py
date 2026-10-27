import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.config import load_config
from upscayl_video.encode import EncodeOptions
from upscayl_video.errors import UsageError
from upscayl_video.pipeline import (
    RunOptions,
    SplitOptions,
    UpscaleOptions,
    _auto_chunk_seconds,
    run_all,
)
from upscayl_video.util import Logger
from tests.util import find_ffmpeg, find_ffprobe, make_clip


class TestRun(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = find_ffmpeg()
        if cls.ffmpeg is None:
            raise unittest.SkipTest("ffmpeg not available")
        cls.ffprobe = find_ffprobe(cls.ffmpeg)
        cls.td = tempfile.TemporaryDirectory()
        cls.root = Path(cls.td.name)
        cls.a = cls.root / "a.mp4"
        cls.b = cls.root / "b.mp4"
        make_clip(cls.ffmpeg, cls.a, duration=1.0, size="160x120", fps=30)
        make_clip(cls.ffmpeg, cls.b, duration=1.0, size="160x120", fps=30)
        cls.binary = cls.root / "fake-upscayl"
        cls.binary.write_bytes(b"")
        cls.models = cls.root / "models"
        cls.models.mkdir()
        (cls.models / "m.param").write_text("x", encoding="utf-8")
        (cls.models / "m.bin").write_bytes(b"x")

    @classmethod
    def tearDownClass(cls):
        cls.td.cleanup()

    def test_run_two_videos_with_fake_upscaler(self):
        cfg = load_config(None, overrides={
            "ffmpeg": self.ffmpeg,
            "ffprobe": self.ffprobe,
            "work_dir": str(self.root / "work"),
            "upscayl_bin": str(self.binary),
            "models_dir": str(self.models),
        })

        def fake_upscale(job, paths, **kwargs):
            job.upscaled_dir.mkdir(exist_ok=True)
            for frame in job.frames_dir.glob("frame_*.png"):
                (job.upscaled_dir / frame.name).write_bytes(frame.read_bytes())
            return job.get_int("frame_count")

        options = RunOptions(
            split=SplitOptions(
                fps=None, start=None, end=None, format="png", jpeg_quality=1,
                png_compression=3, denoise="none", tonemap=False, decode="cpu",
                scale=2, target_height=None, model="m", verify_frames=False,
                recursive=False, force=False,
            ),
            upscale=UpscaleOptions(model="m", scale=2, tile="128", batch_size=2),
            encode=EncodeOptions(encoder="cpu", preset="mp4-h264", audio="copy"),
            cleanup=False,
            stop_on_error=False,
            chunk_seconds="0",
        )
        with patch("upscayl_video.pipeline.upscale_frames", side_effect=fake_upscale):
            results = run_all([self.a, self.b], cfg, options, Logger(quiet=True))
        self.assertEqual(len(results), 2)
        self.assertTrue(all(result.output and result.output.exists() for result in results))

    def test_auto_chunk_uses_cap(self):
        cfg = load_config(None, overrides={
            "ffmpeg": self.ffmpeg,
            "ffprobe": self.ffprobe,
            "work_dir": str(self.root / "work-auto"),
            "upscayl_bin": str(self.binary),
            "models_dir": str(self.models),
            "max_work_gb": "1",
            "min_free_gb": "0",
        })
        options = RunOptions(
            split=SplitOptions(
                fps=None, start=None, end=None, format="png", jpeg_quality=1,
                png_compression=3, denoise="none", tonemap=False, decode="cpu",
                scale=2, target_height=None, model="m", verify_frames=False,
                recursive=False, force=False,
            ),
            upscale=UpscaleOptions(model="m", scale=2, tile="128", batch_size=2),
            encode=EncodeOptions(encoder="cpu", preset="mp4-h264", audio="copy"),
            cleanup=False,
            stop_on_error=False,
            chunk_seconds="auto",
        )
        seconds = _auto_chunk_seconds(self.a, cfg, options, Logger(quiet=True))
        self.assertEqual(seconds, 60)

    def test_run_dry_run_creates_no_job(self):
        work = self.root / "work-dry"
        cfg = load_config(None, overrides={
            "ffmpeg": self.ffmpeg,
            "ffprobe": self.ffprobe,
            "work_dir": str(work),
            "upscayl_bin": str(self.binary),
            "models_dir": str(self.models),
        })
        options = RunOptions(
            split=SplitOptions(
                fps=None, start=None, end=None, format="png", jpeg_quality=1,
                png_compression=3, denoise="none", tonemap=False, decode="cpu",
                scale=2, target_height=None, model="m", verify_frames=False,
                recursive=False, force=False,
            ),
            upscale=UpscaleOptions(model="m", scale=2, tile="128", batch_size=2),
            encode=EncodeOptions(encoder="cpu", preset="mp4-h264", audio="copy"),
            cleanup=False,
            stop_on_error=False,
            chunk_seconds="auto",
        )
        results = run_all(
            [self.a], cfg, options, Logger(quiet=True), dry_run=True
        )
        self.assertEqual(len(results), 1)
        self.assertIsNone(results[0].output)
        self.assertFalse(work.exists())

    def test_run_rejects_file_output_for_multiple_inputs(self):
        cfg = load_config(None, overrides={
            "ffmpeg": self.ffmpeg,
            "ffprobe": self.ffprobe,
            "work_dir": str(self.root / "work-multi"),
            "upscayl_bin": str(self.binary),
            "models_dir": str(self.models),
        })
        options = RunOptions(
            split=SplitOptions(
                fps=None, start=None, end=None, format="png", jpeg_quality=1,
                png_compression=3, denoise="none", tonemap=False, decode="cpu",
                scale=2, target_height=None, model="m", verify_frames=False,
                recursive=False, force=False,
            ),
            upscale=UpscaleOptions(model="m", scale=2, tile="128", batch_size=2),
            encode=EncodeOptions(
                encoder="cpu", preset="mp4-h264", audio="copy",
                output=Path("one.mp4"),
            ),
            cleanup=False,
            stop_on_error=False,
            chunk_seconds="0",
        )
        with self.assertRaises(UsageError):
            run_all([self.a, self.b], cfg, options, Logger(quiet=True))


if __name__ == "__main__":
    unittest.main()
