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

    def test_doctor_help(self):
        result = subprocess.run(
            [sys.executable, str(LAUNCHER), "doctor", "--help"],
            text=True, encoding="utf-8", errors="replace",
            capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--skip-upscayl-smoke", result.stdout)

    def test_status_help(self):
        result = subprocess.run(
            [sys.executable, str(LAUNCHER), "status", "--help"],
            text=True, encoding="utf-8", errors="replace",
            capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_clean_help(self):
        result = subprocess.run(
            [sys.executable, str(LAUNCHER), "clean", "--help"],
            text=True, encoding="utf-8", errors="replace",
            capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--all-intermediates", result.stdout)

    def test_upscale_help(self):
        result = subprocess.run(
            [sys.executable, str(LAUNCHER), "upscale", "--help"],
            text=True, encoding="utf-8", errors="replace",
            capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--tile", result.stdout)

    def test_run_help(self):
        result = subprocess.run(
            [sys.executable, str(LAUNCHER), "run", "--help"],
            text=True, encoding="utf-8", errors="replace",
            capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--chunk-seconds", result.stdout)

    def test_assemble_help(self):
        result = subprocess.run(
            [sys.executable, str(LAUNCHER), "assemble", "--help"],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--preset", result.stdout)

    def test_assemble_command_and_explicit_collision(self):
        ffmpeg = find_ffmpeg()
        if ffmpeg is None:
            self.skipTest("ffmpeg not available")
        ffprobe = find_ffprobe(ffmpeg)
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            clip = root / "clip.mp4"
            work = root / "work"
            make_clip(ffmpeg, clip, duration=1.0, size="160x120", fps=30)
            split = subprocess.run(
                [
                    sys.executable, str(LAUNCHER), "split", str(clip),
                    "--work-dir", str(work), "--ffmpeg", ffmpeg,
                    "--ffprobe", ffprobe, "--decode", "cpu",
                ],
                text=True, encoding="utf-8", errors="replace",
                capture_output=True, check=False,
            )
            self.assertEqual(split.returncode, 0, split.stderr or split.stdout)
            job_dir = work / "clip"
            frames = sorted((job_dir / "frames").glob("frame_*.png"))
            upscaled = job_dir / "upscaled"
            upscaled.mkdir()
            for frame in frames:
                (upscaled / frame.name).write_bytes(frame.read_bytes())

            assemble = subprocess.run(
                [
                    sys.executable, str(LAUNCHER), "assemble", str(job_dir),
                    "--ffmpeg", ffmpeg, "--ffprobe", ffprobe,
                    "--encoder", "cpu", "--preset", "mp4-h264",
                ],
                text=True, encoding="utf-8", errors="replace",
                capture_output=True, check=False,
            )
            self.assertEqual(assemble.returncode, 0, assemble.stderr or assemble.stdout)
            output = job_dir / "output" / "clip_upscaled.mp4"
            self.assertTrue(output.exists())

            collision = subprocess.run(
                [
                    sys.executable, str(LAUNCHER), "assemble", str(job_dir),
                    "--ffmpeg", ffmpeg, "--ffprobe", ffprobe,
                    "--encoder", "cpu", "--preset", "mp4-h264",
                    "--output", str(output),
                ],
                text=True, encoding="utf-8", errors="replace",
                capture_output=True, check=False,
            )
            self.assertEqual(collision.returncode, 4, collision.stderr or collision.stdout)


if __name__ == "__main__":
    unittest.main()
