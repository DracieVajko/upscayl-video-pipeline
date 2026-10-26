import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tests.util import find_ffmpeg, find_ffprobe, make_clip, ffprobe_json


class TestManualWorkflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = find_ffmpeg()
        if cls.ffmpeg is None:
            raise unittest.SkipTest("ffmpeg not available")
        cls.ffprobe = find_ffprobe(cls.ffmpeg)
        cls.td = tempfile.TemporaryDirectory()
        cls.root = Path(cls.td.name)
        cls.clip = cls.root / "test diakritika žluťoučký.mp4"
        make_clip(cls.ffmpeg, cls.clip, duration=2.0, size="160x120", fps=30)
        cls.work = cls.root / "work"

    @classmethod
    def tearDownClass(cls):
        cls.td.cleanup()

    def test_split_rename_and_assemble(self):
        root = Path(__file__).resolve().parents[2]
        launcher = root / "upscayl-video.py"
        split = subprocess.run(
            [sys.executable, str(launcher), "split", str(self.clip),
             "--work-dir", str(self.work), "--format", "png", "--decode", "cpu",
             "--ffmpeg", self.ffmpeg, "--ffprobe", self.ffprobe],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
        )
        self.assertEqual(split.returncode, 0, split.stderr or split.stdout)
        job_dir = self.work / "test_diakritika_žluťoučký"
        self.assertTrue(job_dir.exists(), list(self.work.iterdir()))
        frames = sorted((job_dir / "frames").glob("frame_*.png"))
        self.assertEqual(len(frames), 60)
        upscaled = job_dir / "upscaled"
        upscaled.mkdir()
        for frame in frames:
            (upscaled / f"{frame.stem}_upscayl_4x_upscayl-standard-4x.png").write_bytes(frame.read_bytes())
        assemble = subprocess.run(
            [sys.executable, str(launcher), "assemble", str(job_dir),
             "--preset", "mp4-h264", "--encoder", "cpu", "--audio", "copy", "--subs", "auto",
             "--ffmpeg", self.ffmpeg, "--ffprobe", self.ffprobe],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
        )
        self.assertEqual(assemble.returncode, 0, assemble.stderr or assemble.stdout)
        output = job_dir / "output" / "test diakritika žluťoučký_upscaled.mp4"
        self.assertTrue(output.exists())
        self.assertFalse((job_dir / "sequence").exists())
        info = ffprobe_json(self.ffprobe, output)
        video = [s for s in info["streams"] if s["codec_type"] == "video"][0]
        self.assertEqual((video["width"], video["height"]), (160, 120))
        self.assertAlmostEqual(float(info["format"]["duration"]), 2.0, delta=0.15)
        self.assertTrue(any(s["codec_type"] == "audio" for s in info["streams"]))


if __name__ == "__main__":
    unittest.main()
