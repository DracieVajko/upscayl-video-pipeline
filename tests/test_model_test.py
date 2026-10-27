"""Tests for the model comparison command."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from upscayl_video.errors import ValidationError
from upscayl_video.model_test import (
    _collect_images,
    _filter_models,
    _report_html,
    collect_models,
    sample_timestamps,
)


class SamplingTests(unittest.TestCase):
    def test_seeded_sample_is_deterministic_and_spread(self) -> None:
        points, seed = sample_timestamps(60.0, 3, 7)
        again, again_seed = sample_timestamps(60.0, 3, 7)
        self.assertEqual(seed, 7)
        self.assertEqual(again_seed, 7)
        self.assertEqual(points, again)
        self.assertEqual(len(points), 3)
        self.assertEqual(points, sorted(points))
        self.assertEqual(len(set(points)), 3)
        for index, point in enumerate(points):
            low = index * 20.0 + 2.0
            high = (index + 1) * 20.0 - 2.0
            self.assertGreaterEqual(point, low)
            self.assertLessEqual(point, high)

    def test_different_seed_changes_sample(self) -> None:
        first, _ = sample_timestamps(60.0, 3, 7)
        second, _ = sample_timestamps(60.0, 3, 8)
        self.assertNotEqual(first, second)

    def test_rejects_empty_video(self) -> None:
        with self.assertRaises(ValidationError):
            sample_timestamps(0.0, 3, 1)


class ModelDiscoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.td = tempfile.TemporaryDirectory()
        self.addCleanup(self.td.cleanup)
        self.root = Path(self.td.name)
        self.first = self.root / "models-a"
        self.second = self.root / "models-b"
        self.first.mkdir()
        self.second.mkdir()
        for directory, name in ((self.first, "alpha"), (self.first, "beta"), (self.second, "alpha")):
            (directory / f"{name}.param").write_text("x")
            (directory / f"{name}.bin").write_text("x")

    def test_first_directory_wins_duplicates(self) -> None:
        models = collect_models([self.first, self.second])
        self.assertEqual([name for name, _ in models], ["alpha", "beta"])
        self.assertEqual(dict(models)["alpha"], self.first)

    def test_filter_is_case_insensitive(self) -> None:
        models = collect_models([self.first])
        selected = _filter_models(models, ["ALPHA"])
        self.assertEqual([name for name, _ in selected], ["alpha"])

    def test_unknown_model_is_rejected(self) -> None:
        models = collect_models([self.first])
        with self.assertRaises(ValidationError):
            _filter_models(models, ["missing"])


class ReportTests(unittest.TestCase):
    def test_report_contains_models_and_relative_paths(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            test_dir = Path(td)
            (test_dir / "original").mkdir()
            (test_dir / "m1").mkdir()
            original = test_dir / "original" / "frame_00000001.png"
            output = test_dir / "m1" / "frame_00000001.png"
            original.write_bytes(b"x")
            output.write_bytes(b"xx")
            media = SimpleNamespace(width=960, height=720, duration=5.0)
            report = _report_html(
                test_dir,
                Path("clip.mp4"),
                media,
                [1.0],
                42,
                ["m1", "broken"],
                {1: original},
                {"m1": {1: output}},
                {"broken": "boom"},
            )
            self.assertIn("original/frame_00000001.png", report)
            self.assertIn("m1/frame_00000001.png", report)
            self.assertIn("m1", report)
            self.assertIn("boom", report)
            self.assertIn("Frame 1", report)

    def test_collect_images_handles_suffixes(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "frame_00000002_upscayl_4x.png").write_bytes(b"x")
            (root / "frame_00000001.png").write_bytes(b"x")
            images = _collect_images(root)
            self.assertEqual(set(images), {1, 2})


if __name__ == "__main__":
    unittest.main()
