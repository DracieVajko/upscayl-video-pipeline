import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.config import load_config
from upscayl_video.errors import DependencyError, ValidationError
from upscayl_video.upscayl import (
    ModelInfo,
    UpscaylPaths,
    discover_upscayl,
    find_nvidia_icd,
    list_models,
    resolve_batch_size,
    resolve_tile,
)


class TestModels(unittest.TestCase):
    def test_lists_complete_pairs_only(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "a.param").write_text("x", encoding="utf-8")
            (root / "a.bin").write_bytes(b"x")
            (root / "b.param").write_text("x", encoding="utf-8")
            models = list_models(root)
            self.assertEqual([model.name for model in models], ["a"])

    def test_missing_models_dir_raises(self):
        with self.assertRaises(DependencyError):
            list_models(Path("does-not-exist"))


class TestTile(unittest.TestCase):
    def test_auto_by_vram(self):
        self.assertEqual(resolve_tile("auto", 4096), 128)
        self.assertEqual(resolve_tile("auto", 6144), 256)
        self.assertEqual(resolve_tile("auto", 12288), 512)
        self.assertEqual(resolve_tile("auto", None), 256)

    def test_explicit_tile(self):
        self.assertEqual(resolve_tile("128", 6144), 128)

    def test_tile_below_32_is_rejected(self):
        with self.assertRaises(ValidationError):
            resolve_tile("16", 6144)


class TestBatch(unittest.TestCase):
    def test_large_frames_use_smaller_batch(self):
        self.assertEqual(resolve_batch_size(0, 1920, 1080), 100)
        self.assertEqual(resolve_batch_size(0, 3840, 2160), 50)

    def test_explicit_batch_wins(self):
        self.assertEqual(resolve_batch_size(7, 3840, 2160), 7)


class TestDiscovery(unittest.TestCase):
    def test_config_binary_and_models(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            binary = root / ("upscayl-bin.exe" if __import__("os").name == "nt" else "upscayl-bin")
            binary.write_bytes(b"")
            models = root / "models"
            models.mkdir()
            (models / "m.param").write_text("x", encoding="utf-8")
            (models / "m.bin").write_bytes(b"x")
            cfg = load_config(None, overrides={
                "ffmpeg": __import__("sys").executable,
                "ffprobe": __import__("sys").executable,
                "upscayl_bin": str(binary),
                "models_dir": str(models),
            })
            paths = discover_upscayl(cfg)
            self.assertEqual(paths.binary, binary.resolve())
            self.assertEqual(paths.models_dir, models.resolve())

    def test_missing_binary_raises(self):
        cfg = load_config(None, overrides={
            "ffmpeg": __import__("sys").executable,
            "ffprobe": __import__("sys").executable,
            "upscayl_bin": "/missing/upscayl-bin",
        })
        with self.assertRaises(DependencyError):
            discover_upscayl(cfg)


class TestIcd(unittest.TestCase):
    @patch("upscayl_video.upscayl._find_nvidia_icd_windows", return_value=Path("C:/nv-vk64.json"))
    def test_auto_returns_nvidia_icd(self, _find):
        self.assertEqual(find_nvidia_icd(), Path("C:/nv-vk64.json"))

    @patch("upscayl_video.upscayl._find_nvidia_icd_windows", return_value=None)
    def test_auto_without_nvidia_returns_none(self, _find):
        self.assertIsNone(find_nvidia_icd())


if __name__ == "__main__":
    unittest.main()
