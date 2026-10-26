import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.job import Job
from upscayl_video.progress import Progress
from upscayl_video.upscayl import UpscaylPaths, missing_indices, upscale_frames
from upscayl_video.util import Logger


class TestProgressBasics(unittest.TestCase):
    def test_counts_and_line(self):
        progress = Progress("upscale", 10)
        progress.update(3)
        self.assertEqual(progress.done, 3)
        self.assertIn("3/10", progress.line())


class TestMissing(unittest.TestCase):
    def test_missing_indices(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src = root / "frames"
            out = root / "upscaled"
            src.mkdir()
            out.mkdir()
            for i in (1, 2, 3):
                (src / f"frame_{i:08d}.png").write_bytes(b"x")
            (out / "frame_00000001.png").write_bytes(b"y")
            (out / "frame_00000002.png").write_bytes(b"")
            self.assertEqual(missing_indices(src, out, 3), [2, 3])


class TestBatch(unittest.TestCase):
    def test_upscale_calls_batches_and_moves_outputs(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            job_dir = root / "job"
            job_dir.mkdir()
            (job_dir / "job.txt").write_text("source=x\n", encoding="utf-8")
            job = Job.load(job_dir)
            job.set("frame_count", "3")
            job.frames_dir.mkdir()
            for i in (1, 2, 3):
                (job.frames_dir / f"frame_{i:08d}.png").write_bytes(b"x")
            models = root / "models"
            models.mkdir()
            (models / "m.param").write_text("x", encoding="utf-8")
            (models / "m.bin").write_bytes(b"x")
            paths = UpscaylPaths(Path("upscayl-bin"), models)
            calls = []

            def fake_run(args, **kwargs):
                calls.append(args)
                in_dir = Path(args[args.index("-i") + 1])
                out_dir = Path(args[args.index("-o") + 1])
                for src in in_dir.iterdir():
                    (out_dir / src.name).write_bytes(b"up")
                return type("R", (), {"returncode": 0, "stderr": "", "stdout": ""})()

            with patch("upscayl_video.upscayl.run_command", side_effect=fake_run):
                count = upscale_frames(
                    job, paths, model="m", scale=2, output_dir=job.upscaled_dir,
                    tile=128, batch_size=2, gpu=0, icd=None, threads="1:2:2",
                    retry=1, logger=Logger(quiet=True),
                )
            self.assertEqual(count, 3)
            self.assertEqual(len(calls), 2)
            self.assertEqual(len(list(job.upscaled_dir.glob("*.png"))), 3)


if __name__ == "__main__":
    unittest.main()
