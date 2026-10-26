import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.config import load_config
from upscayl_video.encode import EncodeOptions, EncoderChoice
from upscayl_video.errors import CommandError, EncodeError, ValidationError
from upscayl_video.job import Job
from upscayl_video.pipeline import _resolve_output_path, resolve_jobs, run_assemble
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
    def test_output_cannot_be_the_source(self):
        with tempfile.TemporaryDirectory() as td:
            work = Path(td) / "work"
            source = Path(td) / "a.mp4"
            source.write_bytes(b"x")
            job = Job.create_or_open(work, source, Logger(quiet=True))
            job.save()
            with self.assertRaises(ValidationError):
                _resolve_output_path(
                    job,
                    "mp4",
                    EncodeOptions(output=source, force=True),
                    multiple_jobs=False,
                )

    def test_output_extension_must_match_preset(self):
        with tempfile.TemporaryDirectory() as td:
            work = Path(td) / "work"
            source = Path(td) / "a.mp4"
            source.write_bytes(b"x")
            job = Job.create_or_open(work, source, Logger(quiet=True))
            job.save()
            with self.assertRaises(ValidationError):
                _resolve_output_path(
                    job,
                    "mp4",
                    EncodeOptions(output=Path(td) / "out.mkv", force=True),
                    multiple_jobs=False,
                )

    def test_missing_upscaled_frames_are_rejected_before_encode(self):
        with tempfile.TemporaryDirectory() as td:
            work = Path(td) / "work"
            source = Path(td) / "a.mp4"
            source.write_bytes(b"x")
            job = Job.create_or_open(work, source, Logger(quiet=True))
            job.update_from_media(make_media_info(source))
            job.set("frame_count", "3")
            job.save()
            job.upscaled_dir.mkdir(parents=True)
            (job.upscaled_dir / "frame_00000001.png").write_bytes(b"a")
            (job.upscaled_dir / "frame_00000002.png").write_bytes(b"b")
            cfg = load_config(None, overrides={"work_dir": str(work), "ffmpeg": sys.executable, "ffprobe": sys.executable})
            with patch("upscayl_video.pipeline.probe_media", return_value=make_media_info(source)):
                with self.assertRaises(ValidationError):
                    run_assemble([job], cfg, EncodeOptions(encoder="cpu"), Logger(quiet=True))

    def test_failed_reencode_preserves_old_output(self):
        with tempfile.TemporaryDirectory() as td:
            work = Path(td) / "work"
            source = Path(td) / "a.mp4"
            source.write_bytes(b"x")
            job = Job.create_or_open(work, source, Logger(quiet=True))
            job.update_from_media(make_media_info(source))
            job.set("frame_count", "1")
            job.save()
            job.upscaled_dir.mkdir(parents=True)
            (job.upscaled_dir / "frame_00000001.png").write_bytes(b"a")
            job.output_dir.mkdir()
            output = job.output_dir / "a_upscaled.mp4"
            output.write_bytes(b"old")
            job.mark_done("assemble")
            cfg = load_config(None, overrides={"work_dir": str(work), "ffmpeg": sys.executable, "ffprobe": sys.executable})
            with patch("upscayl_video.pipeline.probe_media", return_value=make_media_info(source)), \
                 patch("upscayl_video.pipeline.probe_first_frame_dimensions", return_value=(320, 240)), \
                 patch("upscayl_video.pipeline.encoder_candidates", return_value=[EncoderChoice("cpu", "libx264")]), \
                 patch("upscayl_video.pipeline.run_command", side_effect=CommandError("boom")):
                with self.assertRaises(EncodeError):
                    run_assemble(
                        [job], cfg,
                        EncodeOptions(encoder="cpu", output=output, force=True),
                        Logger(quiet=True),
                    )
            self.assertEqual(output.read_bytes(), b"old")
            self.assertFalse(job.is_done("assemble"))
            self.assertEqual(list(job.output_dir.glob("*partial*")), [])

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
