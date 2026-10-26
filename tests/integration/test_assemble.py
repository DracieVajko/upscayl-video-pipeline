import tempfile
import unittest
from pathlib import Path

from upscayl_video.config import load_config
from upscayl_video.encode import EncodeOptions
from upscayl_video.pipeline import run_assemble, run_split, SplitOptions
from upscayl_video.util import Logger
from tests.util import find_ffmpeg, find_ffprobe, make_clip


class TestAssembleIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = find_ffmpeg()
        if cls.ffmpeg is None:
            raise unittest.SkipTest("ffmpeg not available")
        cls.ffprobe = find_ffprobe(cls.ffmpeg)
        cls.td = tempfile.TemporaryDirectory()
        cls.root = Path(cls.td.name)
        cls.work = cls.root / "work"
        cls.clip = cls.root / "clip.mp4"
        make_clip(cls.ffmpeg, cls.clip, duration=1.0, size="160x120", fps=30)
        cls.cfg = load_config(None, overrides={"ffmpeg": cls.ffmpeg, "ffprobe": cls.ffprobe, "work_dir": str(cls.work)})
        cls.logger = Logger(quiet=True)
        cls.job = run_split(
            [cls.clip], cls.cfg,
            SplitOptions(
                fps=None, start=None, end=None, format="png", jpeg_quality=1,
                png_compression=3, denoise="none", tonemap=False, decode="cpu",
                scale=2, target_height=None, model="upscayl-standard-4x",
                verify_frames=False, recursive=False, force=False,
            ),
            cls.logger,
        )[0]

    @classmethod
    def tearDownClass(cls):
        cls.td.cleanup()

    def test_assemble_cpu_mp4_with_audio(self):
        self.job.upscaled_dir.mkdir(exist_ok=True)
        for p in sorted((self.job.frames_dir).glob("frame_*.png")):
            (self.job.upscaled_dir / p.name).write_bytes(p.read_bytes())
        outputs = run_assemble(
            [self.job], self.cfg,
            EncodeOptions(encoder="cpu", preset="mp4-h264", audio="copy", subs="auto"),
            self.logger,
        )
        self.assertTrue(outputs[0].exists())
        self.assertGreater(outputs[0].stat().st_size, 0)


if __name__ == "__main__":
    unittest.main()
