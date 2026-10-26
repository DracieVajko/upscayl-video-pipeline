import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.config import load_config
from upscayl_video.encode import EncodeOptions
from upscayl_video.errors import DiskSpaceError
from upscayl_video.pipeline import (
    RunOptions,
    SplitOptions,
    UpscaleOptions,
    run_all,
    run_split,
)
from upscayl_video.util import Logger
from tests.util import find_ffmpeg, find_ffprobe, make_clip


class TestChunkResume(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = find_ffmpeg()
        if cls.ffmpeg is None:
            raise unittest.SkipTest("ffmpeg not available")
        cls.ffprobe = find_ffprobe(cls.ffmpeg)
        cls.td = tempfile.TemporaryDirectory()
        cls.root = Path(cls.td.name)
        cls.clip = cls.root / "clip.mp4"
        make_clip(cls.ffmpeg, cls.clip, duration=20.0, size="160x120", fps=30)
        cls.binary = cls.root / "fake-upscayl"
        cls.binary.write_bytes(b"")
        cls.models = cls.root / "models"
        cls.models.mkdir()
        (cls.models / "m.param").write_text("x", encoding="utf-8")
        (cls.models / "m.bin").write_bytes(b"x")

    @classmethod
    def tearDownClass(cls):
        cls.td.cleanup()

    def options(self):
        return RunOptions(
            split=SplitOptions(
                fps=None, start=None, end=None, format="png", jpeg_quality=1,
                png_compression=3, denoise="none", tonemap=False, decode="cpu",
                scale=2, target_height=None, model="m", verify_frames=False,
                recursive=False, force=False,
            ),
            upscale=UpscaleOptions(model="m", scale=2, tile="128", batch_size=50),
            encode=EncodeOptions(
                encoder="cpu", preset="mp4-h264", audio="copy", keep_chunks=True
            ),
            cleanup=False,
            stop_on_error=True,
            chunk_seconds="10",
        )

    def config(self):
        return load_config(None, overrides={
            "ffmpeg": self.ffmpeg,
            "ffprobe": self.ffprobe,
            "work_dir": str(self.root / "work"),
            "upscayl_bin": str(self.binary),
            "models_dir": str(self.models),
        })

    def test_resume_skips_done_chunk(self):
        cfg = self.config()

        def fake_upscale(job, paths, *, source_dir, total_frames, output_dir, **kwargs):
            output_dir.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                [
                    self.ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
                    "-framerate", "30", "-start_number", "1",
                    "-i", str(Path(source_dir) / "frame_%08d.png"),
                    "-vf", "scale=iw*2:ih*2",
                    str(Path(output_dir) / "frame_%08d.png"),
                ],
                check=True,
                capture_output=True,
            )
            return total_frames

        with patch("upscayl_video.pipeline.upscale_frames", side_effect=fake_upscale):
            first = run_all([self.clip], cfg, self.options(), Logger(quiet=True))[0]
        self.assertIsNone(first.error)
        job = first.job
        chunks = sorted((job.chunks_dir).glob("chunk_*.ts"))
        self.assertEqual(len(chunks), 2)
        second_segment = chunks[1]
        second_marker = job.path / ".done_chunk_0002"
        second_segment.unlink()
        second_marker.unlink()

        calls = []

        def counted(job, paths, **kwargs):
            calls.append(1)
            return fake_upscale(job, paths, **kwargs)

        with patch("upscayl_video.pipeline.upscale_frames", side_effect=counted):
            second = run_all([self.clip], cfg, self.options(), Logger(quiet=True))[0]
        self.assertIsNone(second.error)
        self.assertEqual(len(calls), 1)

    def test_low_disk_aborts_chunk(self):
        cfg = self.config()
        with patch("upscayl_video.pipeline.free_bytes", return_value=0):
            with self.assertRaises(Exception):
                run_all([self.clip], cfg, self.options(), Logger(quiet=True))


if __name__ == "__main__":
    unittest.main()
