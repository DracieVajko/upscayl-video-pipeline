import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.config import load_config
from upscayl_video.encode import EncodeOptions
from upscayl_video.pipeline import (
    RunOptions,
    SplitOptions,
    UpscaleOptions,
    run_all,
)
from upscayl_video.util import Logger
from tests.util import ffprobe_json, find_ffmpeg, find_ffprobe, make_clip


class TestChunkedRun(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = find_ffmpeg()
        if cls.ffmpeg is None:
            raise unittest.SkipTest("ffmpeg not available")
        cls.ffprobe = find_ffprobe(cls.ffmpeg)
        cls.td = tempfile.TemporaryDirectory()
        cls.root = Path(cls.td.name)
        cls.clip = cls.root / "long.mp4"
        make_clip(cls.ffmpeg, cls.clip, duration=20.0, size="160x120", fps=30)
        cls.binary = cls.root / "fake-upscayl"
        cls.binary.write_bytes(b"")
        cls.models = cls.root / "models"
        cls.models.mkdir()
        (cls.models / "m.param").write_text("x", encoding="utf-8")
        (cls.models / "m.bin").write_bytes(b"x")

    @classmethod
    def tearDownClass(cls):
        cls.td.cleanup()

    def test_two_chunks_audio_sync(self):
        cfg = load_config(None, overrides={
            "ffmpeg": self.ffmpeg,
            "ffprobe": self.ffprobe,
            "work_dir": str(self.root / "work"),
            "upscayl_bin": str(self.binary),
            "models_dir": str(self.models),
        })

        def fake_upscale(job, paths, *, source_dir, total_frames, output_dir, **kwargs):
            output_dir.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                [
                    self.ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
                    "-framerate", "30", "-start_number", "1",
                    "-i", str(Path(source_dir) / "frame_%08d.png"),
                    "-vf", "scale=iw*2:ih*2",
                    str(Path(output_dir) / "frame_%08d.png"),
                ],
                check=True,
                capture_output=True,
            )
            return total_frames

        options = RunOptions(
            split=SplitOptions(
                fps=None, start=None, end=None, format="png", jpeg_quality=1,
                png_compression=3, denoise="none", tonemap=False, decode="cpu",
                scale=2, target_height=None, model="m", verify_frames=False,
                recursive=False, force=False,
            ),
            upscale=UpscaleOptions(model="m", scale=2, tile="128", batch_size=50),
            encode=EncodeOptions(encoder="cpu", preset="mp4-h264", audio="copy"),
            cleanup=False,
            stop_on_error=True,
            chunk_seconds="10",
        )
        with patch("upscayl_video.pipeline.upscale_frames", side_effect=fake_upscale):
            results = run_all([self.clip], cfg, options, Logger(quiet=True))
        self.assertEqual(len(results), 1, results[0].error)
        self.assertIsNone(results[0].error)
        output = results[0].output
        self.assertIsNotNone(output)
        self.assertTrue(output.exists())
        info = ffprobe_json(self.ffprobe, output)
        video = [s for s in info["streams"] if s["codec_type"] == "video"][0]
        self.assertEqual((video["width"], video["height"]), (320, 240))
        self.assertAlmostEqual(float(info["format"]["duration"]), 20.0, delta=0.3)
        self.assertTrue(any(s["codec_type"] == "audio" for s in info["streams"]))
        self.assertFalse((results[0].job.path / "chunks").exists())


if __name__ == "__main__":
    unittest.main()
