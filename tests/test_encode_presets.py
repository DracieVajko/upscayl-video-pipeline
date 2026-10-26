import unittest
from pathlib import Path
from unittest.mock import patch

from upscayl_video.encode import (
    PRESETS,
    EncoderChoice,
    encoder_candidates,
    resolve_preset,
    resolve_quality,
    video_codec_args,
)
from upscayl_video.errors import DependencyError, ValidationError


class TestPresets(unittest.TestCase):
    def test_all_presets_exist(self):
        self.assertEqual(set(PRESETS), {"mp4-h264", "mp4-hevc", "mkv-hevc", "mov-prores"})

    def test_resolve(self):
        self.assertEqual(resolve_preset("mp4-h264").extension, "mp4")
        self.assertEqual(resolve_preset("mov-prores").codec, "prores")

    def test_unknown_preset(self):
        with self.assertRaises(ValidationError):
            resolve_preset("nope")

    def test_quality_values(self):
        self.assertEqual(resolve_quality(PRESETS["mp4-h264"], "fast", None), 22)
        self.assertEqual(resolve_quality(PRESETS["mp4-h264"], "balanced", None), 20)
        self.assertEqual(resolve_quality(PRESETS["mp4-h264"], "quality", None), 18)
        self.assertEqual(resolve_quality(PRESETS["mp4-hevc"], "balanced", None), 22)
        self.assertEqual(resolve_quality(PRESETS["mp4-h264"], "balanced", 17), 17)

    def test_unknown_quality_is_rejected(self):
        with self.assertRaises(ValidationError):
            resolve_quality(PRESETS["mp4-h264"], "ultra", None)

    def test_prores_rejects_crf(self):
        with self.assertRaises(ValidationError):
            resolve_quality(PRESETS["mov-prores"], "balanced", 18)


class TestEncoderArgs(unittest.TestCase):
    def test_nvenc_args(self):
        choice = EncoderChoice("nvidia", "h264_nvenc", ())
        args = video_codec_args(choice, 20, ten_bit=False)
        self.assertIn("h264_nvenc", args)
        self.assertIn("-cq", args)
        self.assertIn("20", args)
        self.assertIn("yuv420p", args)

    def test_x264_args(self):
        choice = EncoderChoice("cpu", "libx264", ())
        args = video_codec_args(choice, 20, ten_bit=False)
        self.assertIn("libx264", args)
        self.assertIn("-crf", args)
        self.assertIn("20", args)

    def test_10bit_h264_is_rejected(self):
        choice = EncoderChoice("cpu", "libx264", ())
        with self.assertRaises(ValidationError):
            video_codec_args(choice, 20, ten_bit=True)

    def test_10bit_hevc_uses_p10(self):
        choice = EncoderChoice("cpu", "libx265", ())
        args = video_codec_args(choice, 22, ten_bit=True)
        self.assertIn("yuv420p10le", args)

    def test_prores_args(self):
        choice = EncoderChoice("cpu", "prores_ks", ("3",))
        args = video_codec_args(choice, 0, ten_bit=False)
        self.assertIn("prores_ks", args)
        self.assertIn("yuv422p10le", args)
        self.assertIn("-profile:v", args)


class TestEncoderCandidates(unittest.TestCase):
    @patch(
        "upscayl_video.encode.parse_available_encoders",
        return_value={"h264_nvenc", "h264_amf", "libx264"},
    )
    def test_auto_order(self, _available):
        choices = encoder_candidates(PRESETS["mp4-h264"], "auto", Path("ffmpeg"))
        self.assertEqual([choice.family for choice in choices], ["nvidia", "amd", "cpu"])

    @patch("upscayl_video.encode.parse_available_encoders", return_value={"libx264"})
    def test_auto_falls_back_to_cpu(self, _available):
        choices = encoder_candidates(PRESETS["mp4-h264"], "auto", Path("ffmpeg"))
        self.assertEqual([choice.video_codec for choice in choices], ["libx264"])

    @patch("upscayl_video.encode.parse_available_encoders", return_value={"libx264"})
    def test_forced_missing_encoder_raises(self, _available):
        with self.assertRaises(DependencyError):
            encoder_candidates(PRESETS["mp4-h264"], "nvidia", Path("ffmpeg"))

    @patch("upscayl_video.encode.parse_available_encoders", return_value={"prores_ks"})
    def test_prores_uses_cpu(self, _available):
        choices = encoder_candidates(PRESETS["mov-prores"], "auto", Path("ffmpeg"))
        self.assertEqual([choice.video_codec for choice in choices], ["prores_ks"])


if __name__ == "__main__":
    unittest.main()
