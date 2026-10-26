import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.config import load_config
from upscayl_video.doctor import check_upscayl
from upscayl_video.errors import CommandError, DependencyError
from upscayl_video.upscayl import ModelInfo, UpscaylPaths, smoke_test
from upscayl_video.util import Logger


class TestSmoke(unittest.TestCase):
    @patch("upscayl_video.upscayl.run_command")
    @patch("upscayl_video.upscayl.ffmpeg_make_test_png")
    def test_smoke_success(self, make_png, run):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            make_png.side_effect = lambda path: path.write_bytes(b"png")

            def fake_run(args, **kwargs):
                out = Path(args[args.index("-o") + 1])
                (out / "test.png").write_bytes(b"up")
                return type("R", (), {"returncode": 0, "stdout": "", "stderr": ""})()

            run.side_effect = fake_run
            paths = UpscaylPaths(Path("upscayl-bin"), root)
            ok, detail = smoke_test(paths, "upscayl-lite-4x", 128, None, Logger(quiet=True))
            self.assertTrue(ok, detail)

    @patch("upscayl_video.upscayl.run_command")
    @patch("upscayl_video.upscayl.ffmpeg_make_test_png")
    def test_smoke_failure_reports_stderr(self, make_png, run):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            make_png.side_effect = lambda path: path.write_bytes(b"png")
            run.side_effect = CommandError("vkEnumeratePhysicalDevices failed 5")
            paths = UpscaylPaths(Path("upscayl-bin"), root)
            ok, detail = smoke_test(paths, "upscayl-lite-4x", 128, None, Logger(quiet=True))
            self.assertFalse(ok)
            self.assertIn("vkEnumeratePhysicalDevices", detail)


class TestDoctorUpscayl(unittest.TestCase):
    @patch("upscayl_video.doctor.discover_upscayl", side_effect=DependencyError("missing"))
    def test_missing_upscayl_is_warn(self, _discover):
        cfg = load_config(None, overrides={"ffmpeg": sys.executable, "ffprobe": sys.executable})
        results = check_upscayl(cfg, skip_smoke=True, logger=Logger(quiet=True))
        self.assertTrue(any(r.status == "WARN" for r in results))

    @patch("upscayl_video.doctor.discover_upscayl", return_value=UpscaylPaths(Path("upscayl-bin"), Path("models")))
    @patch("upscayl_video.doctor.list_models", return_value=[ModelInfo("m", Path("m.param"), Path("m.bin"))])
    @patch("upscayl_video.doctor.smoke_test", return_value=(False, "vkEnumeratePhysicalDevices failed 5"))
    def test_smoke_failure_is_fail(self, _smoke, _models, _discover):
        cfg = load_config(None, overrides={"ffmpeg": sys.executable, "ffprobe": sys.executable})
        results = check_upscayl(cfg, skip_smoke=False, logger=Logger(quiet=True))
        self.assertTrue(any(r.status == "FAIL" for r in results))


if __name__ == "__main__":
    unittest.main()
