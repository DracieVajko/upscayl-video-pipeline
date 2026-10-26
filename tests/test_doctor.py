import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.config import load_config
from upscayl_video.doctor import CheckResult, check_encoders, check_ffmpeg, run_doctor
from upscayl_video.util import Logger


class TestDoctor(unittest.TestCase):
    def test_non_ffmpeg_executable_fails(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = load_config(None, overrides={"ffmpeg": sys.executable, "ffprobe": sys.executable, "work_dir": td})
            results = check_ffmpeg(cfg, Logger(quiet=True))
            self.assertTrue(any(r.status == "FAIL" for r in results))

    def test_encoder_parse(self):
        with patch("upscayl_video.doctor.run_command") as run:
            run.return_value.stdout = " V....D libx264 H.264\n V....D libx265 HEVC\n"
            run.return_value.returncode = 0
            results = check_encoders(
                load_config(None, overrides={"ffmpeg": sys.executable, "ffprobe": sys.executable}),
                Logger(quiet=True),
            )
            self.assertTrue(any(r.name == "libx264" and r.status == "OK" for r in results))
            self.assertTrue(any(r.name == "libx265" and r.status == "OK" for r in results))

    def test_low_disk_exit_code(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = load_config(None, overrides={"ffmpeg": sys.executable, "ffprobe": sys.executable, "work_dir": td})
            ok = [CheckResult("ffmpeg", "OK", "test")]
            with patch("upscayl_video.doctor.check_ffmpeg", return_value=ok), \
                 patch("upscayl_video.doctor.check_encoders", return_value=ok), \
                 patch("upscayl_video.doctor.free_bytes", return_value=0):
                code = run_doctor(cfg, work_dir=Path(td), skip_upscayl_smoke=True, verbose=False, logger=Logger(quiet=True))
            self.assertEqual(code, 5)

    def test_missing_required_tool_returns_3(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = load_config(None, overrides={"ffmpeg": sys.executable, "ffprobe": sys.executable, "work_dir": td})
            code = run_doctor(cfg, work_dir=Path(td), skip_upscayl_smoke=True, verbose=False, logger=Logger(quiet=True))
            self.assertEqual(code, 3)

    def test_output_table(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = load_config(None, overrides={"ffmpeg": sys.executable, "ffprobe": sys.executable, "work_dir": td})
            ok = [CheckResult("ffmpeg", "OK", "test")]
            with patch("upscayl_video.doctor.check_ffmpeg", return_value=ok), \
                 patch("upscayl_video.doctor.check_encoders", return_value=ok), \
                 patch("upscayl_video.doctor.check_work_dir", return_value=ok):
                import contextlib
                import io
                buffer = io.StringIO()
                with contextlib.redirect_stdout(buffer):
                    code = run_doctor(cfg, work_dir=Path(td), skip_upscayl_smoke=True, verbose=False, logger=Logger())
                self.assertEqual(code, 0)
                self.assertIn("STATUS", buffer.getvalue())


if __name__ == "__main__":
    unittest.main()
