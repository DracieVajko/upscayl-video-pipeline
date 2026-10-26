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
        self.assertIn("0.1.0", result.stdout)


if __name__ == "__main__":
    unittest.main()
