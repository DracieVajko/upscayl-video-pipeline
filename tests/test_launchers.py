import re
import subprocess
import sys
import unittest
from pathlib import Path


def package_version() -> str:
    """Read the canonical version from the package source."""
    source = (Path(__file__).resolve().parents[1] / "src" / "upscayl_video" / "__init__.py").read_text(
        encoding="utf-8"
    )
    match = re.search(r'^__version__\s*=\s*"([^"]+)"', source, re.MULTILINE)
    if not match:
        raise AssertionError("no __version__ found in src/upscayl_video/__init__.py")
    return match.group(1)


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
        self.assertIn(package_version(), result.stdout)

    def test_all_runtimes_share_one_version(self):
        """V1, V2 PowerShell and V2 bash must declare the same version."""
        root = Path(__file__).resolve().parents[1]
        version = package_version()
        powershell = (root / "v2" / "windows" / "UpscaylVideo.ps1").read_text(encoding="utf-8-sig")
        bash = (root / "v2" / "unix" / "upscayl-video.sh").read_text(encoding="utf-8")
        self.assertIn(f"$script:V2Version = '{version}'", powershell)
        self.assertIn(f'UVP_VERSION="{version}"', bash)

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
