import tempfile
import unittest
from pathlib import Path

from upscayl_video.config import load_config
from upscayl_video.frames import extract_frames
from upscayl_video.job import Job
from upscayl_video.probe import probe_media
from upscayl_video.util import Logger
from tests.util import find_ffmpeg, find_ffprobe, make_clip


class TestExtractIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = find_ffmpeg()
        if cls.ffmpeg is None:
            raise unittest.SkipTest("ffmpeg not available")
        cls.ffprobe = find_ffprobe(cls.ffmpeg)
        cls.td = tempfile.TemporaryDirectory()
        cls.root = Path(cls.td.name)
        cls.clip = cls.root / "clip.mp4"
        make_clip(cls.ffmpeg, cls.clip, duration=1.0, size="160x120", fps=30)

    @classmethod
    def tearDownClass(cls):
        cls.td.cleanup()

    def test_extract_and_resume(self):
        work = self.root / "work"
        logger = Logger(quiet=True)
        source = self.clip
        media = probe_media(Path(self.ffprobe), source, logger)
        job = Job.create_or_open(work, source, logger)
        job.update_from_media(media)
        job.save()
        config = load_config(
            None,
            overrides={
                "ffmpeg": self.ffmpeg,
                "ffprobe": self.ffprobe,
                "work_dir": str(work),
            },
        )
        count = extract_frames(
            job, media, config, fmt="png", jpeg_quality=1, png_compression=3,
            denoise="none", tonemap=False, decode="cpu", start=0.0, end=None,
            verify=True, logger=logger,
        )
        self.assertEqual(count, 30)
        for i in range(26, 31):
            (job.frames_dir / f"frame_{i:08d}.png").unlink()
        count2 = extract_frames(
            job, media, config, fmt="png", jpeg_quality=1, png_compression=3,
            denoise="none", tonemap=False, decode="cpu", start=0.0, end=None,
            verify=True, logger=logger,
        )
        self.assertEqual(count2, 30)


if __name__ == "__main__":
    unittest.main()
