import unittest
from pathlib import Path

from upscayl_video.encode import PRESETS, plan_audio, plan_subtitles
from upscayl_video.errors import ValidationError
from upscayl_video.probe import StreamInfo
from upscayl_video.util import Logger
from tests.factories import make_media_info


AAC = StreamInfo(1, "aac", channels=2)
MP3 = StreamInfo(1, "mp3", channels=2)
PCM = StreamInfo(1, "pcm_s16le", channels=2)
FLAC = StreamInfo(1, "flac", channels=2)
SRT = StreamInfo(2, "subrip")
PGS = StreamInfo(2, "hdmv_pgs_subtitle")


class TestAudio(unittest.TestCase):
    def test_no_audio(self):
        media = make_media_info(Path("x.mp4"))
        plan = plan_audio(media, PRESETS["mp4-h264"], "auto", 192, False)
        self.assertFalse(plan.enabled)

    def test_aac_is_copied_in_mp4(self):
        media = make_media_info(Path("x.mp4"), audio=(AAC,))
        plan = plan_audio(media, PRESETS["mp4-h264"], "auto", 192, False)
        self.assertEqual(plan.streams[0].mode, "copy")

    def test_mp3_is_copied_in_mp4(self):
        media = make_media_info(Path("x.mp4"), audio=(MP3,))
        plan = plan_audio(media, PRESETS["mp4-h264"], "auto", 192, False)
        self.assertEqual(plan.streams[0].mode, "copy")

    def test_pcm_becomes_aac_in_mp4(self):
        media = make_media_info(Path("x.mp4"), audio=(PCM,))
        plan = plan_audio(media, PRESETS["mp4-h264"], "auto", 192, False)
        self.assertEqual(plan.streams[0].mode, "aac")

    def test_flac_is_copied_in_mkv(self):
        media = make_media_info(Path("x.mkv"), audio=(FLAC,))
        plan = plan_audio(media, PRESETS["mkv-hevc"], "auto", 192, False)
        self.assertEqual(plan.streams[0].mode, "copy")

    def test_copy_with_incompatible_codec_raises(self):
        media = make_media_info(Path("x.mp4"), audio=(PCM,))
        with self.assertRaises(ValidationError):
            plan_audio(media, PRESETS["mp4-h264"], "copy", 192, False)

    def test_all_audio_and_per_track_fallback(self):
        media = make_media_info(Path("x.mp4"), audio=(AAC, PCM))
        plan = plan_audio(media, PRESETS["mp4-h264"], "auto", 192, True)
        self.assertEqual([s.mode for s in plan.streams], ["copy", "aac"])

    def test_none_disables_audio(self):
        media = make_media_info(Path("x.mp4"), audio=(AAC,))
        plan = plan_audio(media, PRESETS["mp4-h264"], "none", 192, False)
        self.assertFalse(plan.enabled)


class TestSubtitles(unittest.TestCase):
    def test_srt_in_mp4_becomes_mov_text(self):
        media = make_media_info(Path("x.mp4"), subtitles=(SRT,))
        plan = plan_subtitles(media, PRESETS["mp4-h264"], "auto", Logger(quiet=True))
        self.assertEqual(plan.streams[0].mode, "mov_text")

    def test_srt_in_mkv_is_copied(self):
        media = make_media_info(Path("x.mkv"), subtitles=(SRT,))
        plan = plan_subtitles(media, PRESETS["mkv-hevc"], "auto", Logger(quiet=True))
        self.assertEqual(plan.streams[0].mode, "copy")

    def test_pgs_in_mp4_is_dropped(self):
        media = make_media_info(Path("x.mp4"), subtitles=(PGS,))
        plan = plan_subtitles(media, PRESETS["mp4-h264"], "auto", Logger(quiet=True))
        self.assertEqual(plan.streams, ())
        self.assertEqual(plan.dropped, (2,))

    def test_pgs_copy_in_mp4_raises(self):
        media = make_media_info(Path("x.mp4"), subtitles=(PGS,))
        with self.assertRaises(ValidationError):
            plan_subtitles(media, PRESETS["mp4-h264"], "copy", Logger(quiet=True))


if __name__ == "__main__":
    unittest.main()
