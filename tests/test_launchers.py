import subprocess
import sys
import unittest
from pathlib import Path


class TestLaunchers(unittest.TestCase):
    def test_python_launcher_version(self):
        root = Path(__file__).resolve().parents[1]
        result = subprocess.run(
            [sys.executable, str(root / "upscayl-video.py"), "--version"],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0.3.1", result.stdout)

    @unittest.skipUnless(sys.platform.startswith("win"), "Windows batch test")
    def test_batch_exit_codes(self):
        root = Path(__file__).resolve().parents[1]
        version = subprocess.run(
            ["cmd", "/c", str(root / "upscayl-video.bat"), "--version"],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
        )
        self.assertEqual(version.returncode, 0, version.stderr or version.stdout)
        bad = subprocess.run(
            ["cmd", "/c", str(root / "upscayl-video.bat"), "split", "--definitely-not-an-option"],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
        )
        self.assertEqual(bad.returncode, 2, bad.stderr or bad.stdout)


if __name__ == "__main__":
    unittest.main()
