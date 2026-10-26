import tempfile
import unittest
from pathlib import Path

from upscayl_video.chunking import concat_segments, plan_chunks
from upscayl_video.config import load_config
from upscayl_video.encode import EncodeOptions, EncoderChoice, PRESETS, build_segment_command
from upscayl_video.errors import ValidationError
from upscayl_video.frames import FrameSet
from upscayl_video.pipeline import SplitOptions, run_split
from upscayl_video.util import Logger
from tests.util import ffprobe_json, find_ffmpeg, find_ffprobe, make_clip


class TestPlan(unittest.TestCase):
    def test_exact_boundaries(self):
        chunks = plan_chunks(30.0, 30.0, 10)
        self.assertEqual(
            [(c.start_frame, c.frame_count) for c in chunks],
            [(1, 300), (301, 300), (601, 300)],
        )
        self.assertEqual(chunks[-1].end, 30.0)

    def test_no_lost_frames(self):
        chunks = plan_chunks(10.0, 29.97, 10)
        self.assertEqual(sum(c.frame_count for c in chunks), 300)

    def test_minimum_chunk(self):
        with self.assertRaises(ValidationError):
            plan_chunks(10.0, 30.0, 5)


class TestSegmentConcat(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = find_ffmpeg()
        if cls.ffmpeg is None:
            raise unittest.SkipTest("ffmpeg not available")
        cls.ffprobe = find_ffprobe(cls.ffmpeg)
        cls.td = tempfile.TemporaryDirectory()
        cls.root = Path(cls.td.name)
        cls.clip = cls.root / "clip.mp4"
        make_clip(cls.ffmpeg, cls.clip, duration=2.0, size="160x120", fps=30)
        cfg = load_config(None, overrides={
            "ffmpeg": cls.ffmpeg,
            "ffprobe": cls.ffprobe,
            "work_dir": str(cls.root / "work"),
        })
        cls.job = run_split(
            [cls.clip], cfg,
            SplitOptions(
                fps=None, start=None, end=None, format="png", jpeg_quality=1,
                png_compression=3, denoise="none", tonemap=False, decode="cpu",
                scale=2, target_height=None, model="upscayl-standard-4x",
                verify_frames=False, recursive=False, force=False,
            ),
            Logger(quiet=True),
        )[0]
        cls.cfg = cfg
        cls.logger = Logger(quiet=True)

    @classmethod
    def tearDownClass(cls):
        cls.td.cleanup()

    def test_two_segments_concat(self):
        from upscayl_video.probe import probe_media
        media = probe_media(Path(self.ffprobe), self.clip, self.logger)
        preset = PRESETS["mp4-h264"]
        options = EncodeOptions(encoder="cpu", preset="mp4-h264")
        encoder = EncoderChoice("cpu", "libx264", ())
        frames = sorted(self.job.frames_dir.glob("frame_*.png"))
        first = FrameSet(self.job.frames_dir, "png", tuple(range(1, 31)), tuple(frames[:30]))
        second = FrameSet(self.job.frames_dir, "png", tuple(range(31, 61)), tuple(frames[30:60]))
        segment1 = self.root / "seg1.ts"
        segment2 = self.root / "seg2.ts"
        for frame_set, segment in ((first, segment1), (second, segment2)):
            command = build_segment_command(
                self.job, frame_set, media, preset, encoder, options, segment,
                frame_width=160, frame_height=120,
            )
            command[0] = self.ffmpeg
            import subprocess
            result = subprocess.run(command, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        output = self.root / "concat.ts"
        concat_segments(Path(self.ffmpeg), [segment1, segment2], output, self.logger)
        info = ffprobe_json(self.ffprobe, output)
        self.assertAlmostEqual(float(info["format"]["duration"]), 2.0, delta=0.2)


if __name__ == "__main__":
    unittest.main()
