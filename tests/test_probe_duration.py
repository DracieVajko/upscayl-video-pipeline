from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

from upscayl_video.probe import probe_media
from upscayl_video.util import Logger
from tests.util import ffprobe_json, find_ffmpeg, find_ffprobe


class TestMatroskaDuration(unittest.TestCase):
    """Matroska often omits the video stream duration; the packet tail is used."""

    def test_duration_uses_max_packet_end_with_b_frames(self):
        ffmpeg = find_ffmpeg()
        if not ffmpeg:
            self.skipTest("ffmpeg not available")
        ffprobe = find_ffprobe(ffmpeg)
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "source.mp4"
            result = subprocess.run(
                [
                    ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
                    "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=30",
                    "-t", "5", "-c:v", "libx264", "-preset", "medium",
                    "-pix_fmt", "yuv420p", "-g", "250", "-an", str(source),
                ],
                text=True, encoding="utf-8", errors="replace",
                capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            mkv = root / "clip.mkv"
            result = subprocess.run(
                [ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
                 "-i", str(source), "-c", "copy", str(mkv)],
                text=True, encoding="utf-8", errors="replace",
                capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            data = ffprobe_json(ffprobe, mkv)
            video = next(s for s in data["streams"] if s["codec_type"] == "video")
            if video.get("duration"):
                self.skipTest("this ffmpeg writes a video stream duration")

            info = probe_media(Path(ffprobe), mkv, Logger(quiet=True))
            self.assertAlmostEqual(info.duration, 5.0, delta=0.12)


if __name__ == "__main__":
    unittest.main()

