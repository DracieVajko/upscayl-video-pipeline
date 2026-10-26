import sys
import tempfile
import unittest
from pathlib import Path

from upscayl_video.config import DEFAULTS, load_config
from upscayl_video.errors import DependencyError, ValidationError


FAKE_FFMPEG = Path(sys.executable)


class TestConfig(unittest.TestCase):
    def write_config(self, td: str, text: str) -> Path:
        path = Path(td) / "config.txt"
        path.write_text(text, encoding="utf-8")
        return path

    def test_defaults_are_loaded(self):
        with tempfile.TemporaryDirectory() as td:
            path = self.write_config(
                td,
                f"ffmpeg={FAKE_FFMPEG}\nffprobe={FAKE_FFMPEG}\n",
            )
            cfg = load_config(path)
            self.assertEqual(cfg.work_dir.resolve(), (path.parent / "work").resolve())
            self.assertEqual(cfg.default_preset, "mp4-h264")
            self.assertEqual(cfg.default_scale, 2)
            self.assertIsNone(cfg.upscayl_bin)

    def test_cli_overrides_win(self):
        with tempfile.TemporaryDirectory() as td:
            path = self.write_config(
                td,
                f"ffmpeg={FAKE_FFMPEG}\nffprobe={FAKE_FFMPEG}\ndefault_scale=2\n",
            )
            cfg = load_config(path, overrides={"default_scale": "4"})
            self.assertEqual(cfg.default_scale, 4)

    def test_invalid_scale_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            path = self.write_config(
                td,
                f"ffmpeg={FAKE_FFMPEG}\nffprobe={FAKE_FFMPEG}\ndefault_scale=5\n",
            )
            with self.assertRaises(ValidationError):
                load_config(path)

    def test_missing_executable_is_a_dependency_error(self):
        with tempfile.TemporaryDirectory() as td:
            path = self.write_config(
                td,
                f"ffmpeg={Path(td) / 'missing.exe'}\nffprobe={FAKE_FFMPEG}\n",
            )
            with self.assertRaises(DependencyError):
                load_config(path)

    def test_directory_value_finds_named_executable(self):
        with tempfile.TemporaryDirectory() as td:
            bindir = Path(td) / "bin"
            bindir.mkdir()
            name = "ffmpeg.exe" if sys.platform.startswith("win") else "ffmpeg"
            fake = bindir / name
            fake.write_text("", encoding="utf-8")
            path = self.write_config(
                td,
                f"ffmpeg={bindir}\nffprobe={FAKE_FFMPEG}\n",
            )
            cfg = load_config(path)
            self.assertEqual(cfg.ffmpeg.resolve(), fake.resolve())

    def test_unknown_keys_are_ignored(self):
        with tempfile.TemporaryDirectory() as td:
            path = self.write_config(
                td,
                f"ffmpeg={FAKE_FFMPEG}\nffprobe={FAKE_FFMPEG}\nfuture_key=value\n",
            )
            cfg = load_config(path)
            self.assertEqual(cfg.default_model, DEFAULTS["default_model"])


if __name__ == "__main__":
    unittest.main()
