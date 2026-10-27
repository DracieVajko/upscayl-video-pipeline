"""Tests for publishing the final video and purging the job folder."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from upscayl_video.job import Job
from upscayl_video.pipeline import _publish_and_purge
from upscayl_video.util import Logger


class PublishAndPurgeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.td = tempfile.TemporaryDirectory()
        self.addCleanup(self.td.cleanup)
        self.root = Path(self.td.name)
        self.job_dir = self.root / "work" / "clip"
        (self.job_dir / "output").mkdir(parents=True)
        self.output = self.job_dir / "output" / "clip_upscaled.mp4"
        self.output.write_bytes(b"video")
        self.out_dir = self.root / "output"
        self.config = SimpleNamespace(output_dir=self.out_dir)
        self.logger = Logger(quiet=True)

    def publish(self, output: Path | None = None) -> Path:
        job = Job(self.job_dir, {})
        return _publish_and_purge(job, output or self.output, self.config, self.logger)

    def test_moves_output_and_removes_job(self) -> None:
        target = self.publish()
        self.assertEqual(target, self.out_dir / "clip_upscaled.mp4")
        self.assertEqual(target.read_bytes(), b"video")
        self.assertFalse(self.job_dir.exists())

    def test_collision_gets_suffix(self) -> None:
        self.out_dir.mkdir()
        existing = self.out_dir / "clip_upscaled.mp4"
        existing.write_bytes(b"old")
        target = self.publish()
        self.assertEqual(target, self.out_dir / "clip_upscaled_1.mp4")
        self.assertEqual(existing.read_bytes(), b"old")

    def test_output_outside_job_is_kept(self) -> None:
        outside = self.root / "custom.mp4"
        outside.write_bytes(b"custom")
        target = self.publish(outside)
        self.assertEqual(target, outside)
        self.assertEqual(outside.read_bytes(), b"custom")
        self.assertFalse(self.job_dir.exists())


if __name__ == "__main__":
    unittest.main()
