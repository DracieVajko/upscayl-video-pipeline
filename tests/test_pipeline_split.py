import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.config import load_config
from upscayl_video.errors import DiskSpaceError, ValidationError
from upscayl_video.pipeline import SplitOptions, resolve_inputs, run_split
from upscayl_video.util import Logger
from tests.factories import make_media_info
from tests.util import find_ffmpeg, find_ffprobe, make_clip


class TestResolveInputs(unittest.TestCase):
    def test_scans_directory_and_skips_outputs(self):
        ffmpeg = find_ffmpeg()
        if ffmpeg is None:
            self.skipTest("ffmpeg not available")
        ffprobe = find_ffprobe(ffmpeg)
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "a.mp4").write_bytes(b"a")
            (root / "b.MKV").write_bytes(b"b")
            (root / "note.txt").write_text("x", encoding="utf-8")
            (root / "a_upscaled.mp4").write_bytes(b"c")
            cfg = load_config(None, overrides={"ffmpeg": ffmpeg, "ffprobe": ffprobe})
            inputs = resolve_inputs([str(root)], cfg, recursive=False)
            self.assertEqual([p.name for p in inputs], ["a.mp4", "b.MKV"])


class TestSplit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = find_ffmpeg()
        if cls.ffmpeg is None:
            raise unittest.SkipTest("ffmpeg not available")
        cls.ffprobe = find_ffprobe(cls.ffmpeg)
        cls.td = tempfile.TemporaryDirectory()
        cls.root = Path(cls.td.name)
        cls.clip = cls.root / "clip.mp4"
        make_clip(cls.ffmpeg, cls.clip, duration=1.0, size="160x120", fps=30)

    @classmethod
    def tearDownClass(cls):
        cls.td.cleanup()

    def options(self, **overrides):
        values = dict(
            fps=None, start=None, end=None, format="png", jpeg_quality=1,
            png_compression=3, denoise="none", tonemap=False, decode="cpu",
            scale=2, target_height=None, model="upscayl-standard-4x",
            verify_frames=False, recursive=False, force=False,
        )
        values.update(overrides)
        return SplitOptions(**values)

    def test_split_creates_job_and_frames(self):
        cfg = load_config(None, overrides={"ffmpeg": self.ffmpeg, "ffprobe": self.ffprobe, "work_dir": str(self.root / "work")})
        jobs = run_split([self.clip], cfg, self.options(verify_frames=True), Logger(quiet=True))
        self.assertEqual(len(jobs), 1)
        self.assertEqual(jobs[0].get_int("frame_count"), 30)
        self.assertTrue(jobs[0].is_done("split"))
        self.assertTrue((jobs[0].frames_dir / "frame_00000001.png").exists())

    def test_fps_override_resamples_to_requested_rate(self):
        cfg = load_config(None, overrides={"ffmpeg": self.ffmpeg, "ffprobe": self.ffprobe, "work_dir": str(self.root / "fps-work")})
        jobs = run_split([self.clip], cfg, self.options(fps="60"), Logger(quiet=True))
        self.assertEqual(jobs[0].get_int("frame_count"), 60)
        self.assertEqual(jobs[0].get("fps"), "60/1")

    def test_tonemap_writes_sdr_color_tags(self):
        cfg = load_config(None, overrides={"ffmpeg": self.ffmpeg, "ffprobe": self.ffprobe, "work_dir": str(self.root / "tm-work")})
        media = make_media_info(self.clip, hdr=True, color_trc="smpte2084")
        with patch("upscayl_video.pipeline.probe_media", return_value=media), \
             patch("upscayl_video.pipeline.sample_frame_bytes", return_value=1000), \
             patch("upscayl_video.pipeline.extract_frames", return_value=1):
            job = run_split(
                [self.clip], cfg, self.options(tonemap=True), Logger(quiet=True)
            )[0]
        self.assertEqual(job.get("hdr"), "0")
        self.assertEqual(job.get("color_primaries"), "bt709")
        self.assertEqual(job.get("color_trc"), "bt709")
        self.assertEqual(job.get("colorspace"), "bt709")
        self.assertEqual(job.get("color_range"), "tv")

    def test_dry_run_creates_no_job(self):
        work = self.root / "dry-work"
        cfg = load_config(None, overrides={"ffmpeg": self.ffmpeg, "ffprobe": self.ffprobe, "work_dir": str(work)})
        jobs = run_split([self.clip], cfg, self.options(), Logger(quiet=True), dry_run=True)
        self.assertEqual(jobs, [])
        self.assertFalse(work.exists())

    def test_hdr_without_tonemap_is_rejected(self):
        cfg = load_config(None, overrides={"ffmpeg": self.ffmpeg, "ffprobe": self.ffprobe, "work_dir": str(self.root / "work2")})
        media = make_media_info(self.clip, hdr=True, color_trc="smpte2084")
        with patch("upscayl_video.pipeline.probe_media", return_value=media):
            with self.assertRaises(ValidationError):
                run_split([self.clip], cfg, self.options(), Logger(quiet=True))

    def test_hdr_with_tonemap_is_allowed(self):
        cfg = load_config(None, overrides={"ffmpeg": self.ffmpeg, "ffprobe": self.ffprobe, "work_dir": str(self.root / "work-tm")})
        media = make_media_info(self.clip, hdr=True, color_trc="smpte2084")
        with patch("upscayl_video.pipeline.probe_media", return_value=media), \
             patch("upscayl_video.pipeline.sample_frame_bytes", return_value=1000):
            jobs = run_split(
                [self.clip], cfg, self.options(tonemap=True), Logger(quiet=True), dry_run=True
            )
        self.assertEqual(jobs, [])

    def test_low_disk_is_rejected(self):
        cfg = load_config(None, overrides={"ffmpeg": self.ffmpeg, "ffprobe": self.ffprobe, "work_dir": str(self.root / "work3")})
        with patch("upscayl_video.pipeline.sample_frame_bytes", return_value=10**9):
            with patch("upscayl_video.pipeline.free_bytes", return_value=10**8):
                with self.assertRaises(DiskSpaceError):
                    run_split([self.clip], cfg, self.options(), Logger(quiet=True))


if __name__ == "__main__":
    unittest.main()
