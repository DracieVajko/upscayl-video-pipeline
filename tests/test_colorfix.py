from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

from upscayl_video.encode import normalize_color_tags
from upscayl_video.probe import probe_media
from upscayl_video.util import Logger
from tests.util import ffprobe_json, find_ffmpeg, find_ffprobe


def run(args: list[str]) -> None:
    result = subprocess.run(
        args, text=True, encoding="utf-8", errors="replace",
        capture_output=True, check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr or result.stdout)


class TestColorNormalization(unittest.TestCase):
    """The color-tag remux must not drop audio, subtitles, or data streams."""

    def setUp(self) -> None:
        ffmpeg = find_ffmpeg()
        if not ffmpeg:
            self.skipTest("ffmpeg not available")
        self.ffmpeg = Path(ffmpeg)
        self.ffprobe = Path(find_ffprobe(ffmpeg))

    def _make_source(self, root: Path) -> Path:
        srt = root / "subs.srt"
        srt.write_text(
            "1\n00:00:00,100 --> 00:00:00,800\nHello\n\n"
            "2\n00:00:00,900 --> 00:00:01,500\nWorld\n",
            encoding="utf-8",
        )
        base = root / "base.mp4"
        run([
            str(self.ffmpeg), "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "1", "-c:v", "libx264", "-preset", "ultrafast",
            "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k",
            "-shortest", str(base),
        ])
        tagged = root / "tagged.mp4"
        run([
            str(self.ffmpeg), "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(base), "-i", str(srt),
            "-map", "0:v", "-map", "0:a", "-map", "1:s",
            "-c:v", "copy", "-c:a", "copy", "-c:s", "mov_text",
            "-color_primaries", "bt709", "-color_trc", "iec61966-2-1",
            "-colorspace", "bt709", "-color_range", "tv",
            str(tagged),
        ])
        return tagged

    def test_remux_preserves_all_streams_and_normalizes_tags(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            path = self._make_source(root)
            before = probe_media(self.ffprobe, path, Logger(quiet=True))
            self.assertEqual(len(before.subtitles), 1)
            self.assertEqual(before.color_trc, "iec61966-2-1")

            normalize_color_tags(
                self.ffmpeg, self.ffprobe, path, "mp4", Logger(quiet=True)
            )

            after = probe_media(self.ffprobe, path, Logger(quiet=True))
            self.assertEqual(after.color_primaries, "bt709")
            self.assertEqual(after.color_trc, "bt709")
            self.assertEqual(after.colorspace, "bt709")
            self.assertEqual(after.color_range, "tv")
            self.assertEqual(len(after.audio), 1)
            self.assertEqual(len(after.subtitles), 1)
            self.assertEqual(after.width, 160)
            self.assertEqual(after.height, 120)

            data = ffprobe_json(str(self.ffprobe), path)
            codecs = [s.get("codec_name") for s in data["streams"]]
            self.assertIn("h264", codecs)
            self.assertIn("aac", codecs)
            self.assertIn("mov_text", codecs)


if __name__ == "__main__":
    unittest.main()
