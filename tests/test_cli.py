import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tests.util import find_ffmpeg, find_ffprobe, make_clip

ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "upscayl-video.py"


class TestCli(unittest.TestCase):
    def test_version(self):
        result = subprocess.run(
            [sys.executable, str(LAUNCHER), "--version"],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0.1.0", result.stdout)

    def test_split_help(self):
        result = subprocess.run(
            [sys.executable, str(LAUNCHER), "split", "--help"],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--format", result.stdout)

    def test_split_command(self):
        ffmpeg = find_ffmpeg()
        if ffmpeg is None:
            self.skipTest("ffmpeg not available")
        ffprobe = find_ffprobe(ffmpeg)
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            clip = root / "clip.mp4"
            work = root / "work"
            make_clip(ffmpeg, clip, duration=1.0, size="160x120", fps=30)
            result = subprocess.run(
                [
                    sys.executable,
                    str(LAUNCHER),
                    "split",
                    str(clip),
                    "--work-dir",
                    str(work),
                    "--ffmpeg",
                    ffmpeg,
                    "--ffprobe",
                    ffprobe,
                    "--decode",
                    "cpu",
                ],
                text=True,
                encoding="utf-8",
                errors="replace",
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
            self.assertTrue((work / "clip" / "frames" / "frame_00000001.png").exists())


if __name__ == "__main__":
    unittest.main()
