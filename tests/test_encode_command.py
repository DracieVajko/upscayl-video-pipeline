import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.encode import (
    PRESETS,
    AudioPlan,
    AudioStreamPlan,
    EncodeOptions,
    EncoderChoice,
    SubtitlePlan,
    SubtitleStreamPlan,
    build_assemble_command,
    validate_output,
)
from upscayl_video.errors import OutputValidationError, ValidationError
from upscayl_video.frames import FrameSet
from upscayl_video.job import Job
from upscayl_video.probe import StreamInfo
from upscayl_video.util import Logger
from tests.factories import make_media_info


def make_job(td: str) -> Job:
    root = Path(td)
    job_dir = root / "job"
    job_dir.mkdir()
    (job_dir / "job.txt").write_text("source=x\n", encoding="utf-8")
    return Job.load(job_dir)


class TestCommand(unittest.TestCase):
    def test_mp4_h264_audio_copy_subs_mov_text(self):
        with tempfile.TemporaryDirectory() as td:
            job = make_job(td)
            media = make_media_info(Path("input.mp4"), audio=(StreamInfo(1, "aac", duration=5.0),), subtitles=(StreamInfo(2, "subrip"),))
            frame_set = FrameSet(Path("frames"), "png", (1,), (Path("frames/frame_00000001.png"),))
            args = build_assemble_command(
                job, frame_set, media, PRESETS["mp4-h264"],
                EncoderChoice("cpu", "libx264", ()),
                AudioPlan((AudioStreamPlan(1, "copy"),), True),
                SubtitlePlan((SubtitleStreamPlan(2, "mov_text"),), ()),
                EncodeOptions(encoder="cpu"),
                Path("out.mp4"),
                frame_width=320,
                frame_height=240,
            )
            self.assertIn("-framerate", args)
            self.assertIn("-start_number", args)
            self.assertIn("libx264", args)
            self.assertIn("mov_text", args)
            self.assertIn("+faststart", args)
            self.assertIn("-t", args)
            self.assertNotIn("-shortest", args)
            self.assertIn("1:1", args)  # absolute audio stream index
            self.assertIn("1:2", args)  # absolute subtitle stream index

    def test_no_audio_omits_shortest(self):
        with tempfile.TemporaryDirectory() as td:
            job = make_job(td)
            media = make_media_info(Path("input.mp4"))
            frame_set = FrameSet(Path("frames"), "png", (1,), (Path("frames/frame_00000001.png"),))
            args = build_assemble_command(
                job, frame_set, media, PRESETS["mp4-h264"],
                EncoderChoice("cpu", "libx264", ()),
                AudioPlan((), False), SubtitlePlan((), ()),
                EncodeOptions(encoder="cpu"), Path("out.mp4"),
                frame_width=320, frame_height=240,
            )
            self.assertIn("-an", args)
            self.assertNotIn("-shortest", args)

    def test_10bit_h264_raises(self):
        with tempfile.TemporaryDirectory() as td:
            job = make_job(td)
            media = make_media_info(Path("input.mp4"))
            frame_set = FrameSet(Path("frames"), "png", (1,), (Path("frames/frame_00000001.png"),))
            with self.assertRaises(ValidationError):
                build_assemble_command(
                    job, frame_set, media, PRESETS["mp4-h264"],
                    EncoderChoice("cpu", "libx264", ()),
                    AudioPlan((), False), SubtitlePlan((), ()),
                    EncodeOptions(encoder="cpu", ten_bit=True), Path("out.mp4"),
                    frame_width=320, frame_height=240,
                )

    def test_target_height_and_full_range(self):
        with tempfile.TemporaryDirectory() as td:
            job = make_job(td)
            media = make_media_info(Path("input.mp4"), color_range="pc")
            frame_set = FrameSet(Path("frames"), "png", (1,), (Path("frames/frame_00000001.png"),))
            args = build_assemble_command(
                job, frame_set, media, PRESETS["mp4-h264"],
                EncoderChoice("cpu", "libx264", ()),
                AudioPlan((), False), SubtitlePlan((), ()),
                EncodeOptions(encoder="cpu", target_height=1080), Path("out.mp4"),
                frame_width=3840, frame_height=2160,
            )
            vf = args[args.index("-vf") + 1]
            self.assertIn("scale=-2:1080", vf)
            self.assertIn("in_range=pc", vf)

    def test_range_start_seeks_source_input(self):
        with tempfile.TemporaryDirectory() as td:
            job = make_job(td)
            job.data["range_start"] = "1.000"
            media = make_media_info(Path("input.mp4"), audio=(StreamInfo(1, "aac", duration=5.0),))
            frame_set = FrameSet(Path("frames"), "png", (1,), (Path("frames/frame_00000001.png"),))
            args = build_assemble_command(
                job, frame_set, media, PRESETS["mp4-h264"],
                EncoderChoice("cpu", "libx264", ()),
                AudioPlan((AudioStreamPlan(1, "aac"),), True),
                SubtitlePlan((), ()),
                EncodeOptions(encoder="cpu"), Path("out.mp4"),
                frame_width=320, frame_height=240,
            )
            self.assertLess(args.index("-ss"), args.index(str(job.source_path)))
            self.assertIn("1.000000", args[args.index("-ss") + 1])

    def test_odd_target_height_is_rounded_up(self):
        from upscayl_video.encode import output_dimensions
        width, height = output_dimensions(320, 240, 121, False)
        self.assertEqual((width, height), (164, 122))

    @patch("upscayl_video.encode.probe_media")
    def test_validate_output_wrong_width_raises(self, probe_media):
        with tempfile.TemporaryDirectory() as td:
            job = make_job(td)
            media = make_media_info(Path("input.mp4"))
            job.data["duration"] = "5.0"
            probe_media.return_value = make_media_info(Path("out.mp4"), width=100, height=240)
            with self.assertRaises(OutputValidationError):
                validate_output(
                    Path("ffprobe"), Path("out.mp4"), job, media,
                    EncodeOptions(encoder="cpu"), 320, 240, False, 0,
                    Logger(quiet=True),
                )

    @patch("upscayl_video.encode.probe_media")
    def test_validate_output_missing_audio_raises(self, probe_media):
        with tempfile.TemporaryDirectory() as td:
            job = make_job(td)
            media = make_media_info(Path("input.mp4"), audio=(StreamInfo(1, "aac"),))
            job.data["duration"] = "5.0"
            probe_media.return_value = make_media_info(Path("out.mp4"), width=320, height=240)
            with self.assertRaises(OutputValidationError):
                validate_output(
                    Path("ffprobe"), Path("out.mp4"), job, media,
                    EncodeOptions(encoder="cpu"), 320, 240, True, 0,
                    Logger(quiet=True),
                )

    @patch("upscayl_video.encode.probe_media")
    def test_validate_output_wrong_subtitle_count_raises(self, probe_media):
        with tempfile.TemporaryDirectory() as td:
            job = make_job(td)
            media = make_media_info(Path("input.mp4"), subtitles=(StreamInfo(2, "subrip"),))
            job.data["duration"] = "5.0"
            probe_media.return_value = make_media_info(Path("out.mp4"), width=320, height=240)
            with self.assertRaises(OutputValidationError):
                validate_output(
                    Path("ffprobe"), Path("out.mp4"), job, media,
                    EncodeOptions(encoder="cpu"), 320, 240, False, 1,
                    Logger(quiet=True),
                )


class TestColorFallback(unittest.TestCase):
    def test_rgb_source_maps_gbr_to_yuv_matrix(self):
        with tempfile.TemporaryDirectory() as td:
            job = make_job(td)
            media = make_media_info(
                Path("input.mkv"),
                pix_fmt="bgr0",
                color_primaries=None,
                color_trc=None,
                colorspace="gbr",
                color_range="pc",
            )
            frame_set = FrameSet(
                Path("frames"), "png", (1,),
                (Path("frames/frame_00000001.png"),),
            )
            args = build_assemble_command(
                job, frame_set, media, PRESETS["mp4-h264"],
                EncoderChoice("cpu", "libx264", ()),
                AudioPlan((), False), SubtitlePlan((), ()),
                EncodeOptions(encoder="cpu"), Path("out.mp4"),
                frame_width=320, frame_height=240,
            )
            self.assertIn("smpte170m", args)
            self.assertNotIn("gbr", args)
            self.assertIn("scale=in_range=pc:out_range=tv", args)
            index = args.index("-color_range")
            self.assertEqual(args[index + 1], "tv")


if __name__ == "__main__":
    unittest.main()
