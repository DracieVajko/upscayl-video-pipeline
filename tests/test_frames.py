import tempfile
import unittest
from pathlib import Path

from upscayl_video.errors import ValidationError
from upscayl_video.frames import (
    build_sequence,
    check_frame_signature,
    count_contiguous_frames,
    frame_pattern,
    scan_frames,
    validate_frame_set,
)
from upscayl_video.job import Job
from upscayl_video.util import Logger


class TestPatterns(unittest.TestCase):
    def test_png_pattern(self):
        self.assertEqual(frame_pattern("png"), "frame_%08d.png")

    def test_jpg_pattern(self):
        self.assertEqual(frame_pattern("jpg"), "frame_%08d.jpg")


class TestScanning(unittest.TestCase):
    def test_contiguous_count_stops_at_gap(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            for i in (1, 2, 4):
                (d / f"frame_{i:08d}.png").write_bytes(b"x")
            self.assertEqual(count_contiguous_frames(d, "png"), 2)

    def test_scan_matches_gui_suffix_and_subdir(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            sub = d / "upscayl_png_model_2x"
            sub.mkdir()
            (d / "frame_00000001.png").write_bytes(b"x")
            (sub / "frame_00000002_upscayl_4x_model.png").write_bytes(b"y")
            frames = scan_frames(d, recursive=True)
            self.assertEqual(sorted(frames), [1, 2])

    def test_duplicate_indices_are_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            (d / "frame_00000001.png").write_bytes(b"a")
            (d / "frame_00000001_upscayl.png").write_bytes(b"b")
            with self.assertRaises(ValidationError):
                validate_frame_set(d, expected=1)

    def test_missing_index_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            (d / "frame_00000001.png").write_bytes(b"a")
            (d / "frame_00000003.png").write_bytes(b"c")
            with self.assertRaises(ValidationError):
                validate_frame_set(d, expected=3)

    def test_signature(self):
        with tempfile.TemporaryDirectory() as td:
            png = Path(td) / "a.png"
            png.write_bytes(b"\x89PNG\r\n\x1a\n" + b"rest")
            jpg = Path(td) / "a.jpg"
            jpg.write_bytes(b"\xff\xd8\xff" + b"rest")
            self.assertTrue(check_frame_signature(png))
            self.assertTrue(check_frame_signature(jpg))
            self.assertFalse(check_frame_signature(Path(td) / "a.txt"))


class TestSequence(unittest.TestCase):
    def test_sequence_normalizes_suffixed_names(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            job_dir = root / "job"
            job_dir.mkdir()
            (job_dir / "job.txt").write_text("source=x\n", encoding="utf-8")
            src = root / "upscaled"
            src.mkdir()
            (src / "frame_00000001_upscayl_4x_model.png").write_bytes(b"a")
            (src / "frame_00000002_upscayl_4x_model.png").write_bytes(b"b")
            job = Job.load(job_dir)
            frame_set = validate_frame_set(src, expected=2)
            normalized = build_sequence(frame_set, job, Logger(quiet=True))
            self.assertEqual(normalized.paths[0].name, "frame_00000001.png")
            self.assertEqual(normalized.count, 2)


if __name__ == "__main__":
    unittest.main()
