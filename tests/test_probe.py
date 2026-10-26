import json
import unittest
from pathlib import Path

from upscayl_video.errors import ValidationError
from upscayl_video.probe import (
    is_hdr,
    media_info_from_json,
    normalize_fps,
    parse_rational,
)


class TestFps(unittest.TestCase):
    def test_rational(self):
        self.assertEqual(parse_rational("30000/1001"), (30000, 1001))

    def test_invalid_falls_back(self):
        self.assertEqual(normalize_fps("0/0", "25/1"), (25, 1))

    def test_both_invalid_falls_back_to_30(self):
        self.assertEqual(normalize_fps("0/0", "0/0"), (30, 1))


class TestHdr(unittest.TestCase):
    def test_pq(self):
        self.assertTrue(is_hdr("smpte2084", "yuv420p10le"))

    def test_hlg(self):
        self.assertTrue(is_hdr("arib-std-b67", "yuv420p10le"))

    def test_sdr(self):
        self.assertFalse(is_hdr("bt709", "yuv420p"))


class TestMediaInfo(unittest.TestCase):
    def test_parses_streams_chapters_and_color(self):
        data = json.loads(
            (Path(__file__).parent / "data" / "ffprobe_sample.json").read_text(
                encoding="utf-8"
            )
        )
        source = Path("clip.mp4")
        info = media_info_from_json(source, data)
        self.assertAlmostEqual(info.duration, 5.0)
        self.assertEqual((info.fps_num, info.fps_den), (30, 1))
        self.assertEqual(info.width, 320)
        self.assertEqual(info.height, 240)
        self.assertEqual(len(info.audio), 1)
        self.assertEqual(info.audio[0].codec_name, "aac")
        self.assertEqual(len(info.subtitles), 1)
        self.assertEqual(info.subtitles[0].codec_name, "subrip")
        self.assertEqual(info.chapters, 1)
        self.assertEqual(info.color_primaries, "bt709")
        self.assertFalse(info.hdr)
        self.assertEqual(info.rotation, 0)

    def test_missing_video_stream_is_rejected(self):
        data = {
            "format": {"duration": "5.0"},
            "streams": [{"codec_type": "audio", "codec_name": "aac"}],
        }
        with self.assertRaises(ValidationError):
            media_info_from_json(Path("clip.mp4"), data)


if __name__ == "__main__":
    unittest.main()
