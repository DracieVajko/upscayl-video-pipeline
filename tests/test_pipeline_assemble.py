import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.config import load_config
from upscayl_video.encode import EncodeOptions
from upscayl_video.errors import ValidationError
from upscayl_video.job import Job
from upscayl_video.pipeline import resolve_jobs, run_assemble
from upscayl_video.util import Logger
from tests.factories import make_media_info


class TestResolveJobs(unittest.TestCase):
    def test_job_folder_and_all(self):
        with tempfile.TemporaryDirectory() as td:
            work = Path(td) / "work"
            source = Path(td) / "a.mp4"
            source.write_bytes(b"x")
            job = Job.create_or_open(work, source, Logger(quiet=True))
            job.save()
            cfg = load_config(None, overrides={"work_dir": str(work), "ffmpeg": sys.executable, "ffprobe": sys.executable})
            self.assertEqual([j.path for j in resolve_jobs([str(job.path)], cfg, all_jobs=False)], [job.path])
            self.assertEqual([j.path for j in resolve_jobs([], cfg, all_jobs=True)], [job.path])


class TestAssembleValidation(unittest.TestCase):
    def test_duplicate_frames_are_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            work = Path(td) / "work"
            source = Path(td) / "a.mp4"
            source.write_bytes(b"x")
            job = Job.create_or_open(work, source, Logger(quiet=True))
            job.update_from_media(make_media_info(source))
            job.set("frame_count", "2")
            job.save()
            job.upscaled_dir.mkdir(parents=True)
            (job.upscaled_dir / "frame_00000001.png").write_bytes(b"a")
            (job.upscaled_dir / "frame_00000001_upscayl.png").write_bytes(b"b")
            (job.upscaled_dir / "frame_00000002.png").write_bytes(b"c")
            cfg = load_config(None, overrides={"work_dir": str(work), "ffmpeg": sys.executable, "ffprobe": sys.executable})
            with patch("upscayl_video.pipeline.probe_media", return_value=make_media_info(source)):
                with self.assertRaises(ValidationError):
                    run_assemble([job], cfg, EncodeOptions(encoder="cpu"), Logger(quiet=True))


if __name__ == "__main__":
    unittest.main()
