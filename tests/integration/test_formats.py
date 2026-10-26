import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from upscayl_video.config import load_config
from upscayl_video.encode import EncodeOptions
from upscayl_video.pipeline import SplitOptions, run_assemble, run_split
from upscayl_video.util import Logger
from tests.util import ffprobe_json, find_ffmpeg, find_ffprobe, make_clip


def run(ffmpeg: str, args: list[str]) -> None:
    result = subprocess.run(
        [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", *args],
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr or result.stdout)


def make_odd_clip(ffmpeg: str, path: Path) -> None:
    raw = path.with_suffix(".rgb")
    raw.write_bytes(bytes(321 * 241 * 3 * 30))
    try:
        run(
            ffmpeg,
            [
                "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "321x241",
                "-r", "30", "-i", str(raw), "-frames:v", "30",
                "-c:v", "ffv1", "-pix_fmt", "bgr0", str(path),
            ],
        )
    finally:
        raw.unlink(missing_ok=True)


def make_10bit_clip(ffmpeg: str, path: Path) -> None:
    run(
        ffmpeg,
        [
            "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=30",
            "-t", "1", "-c:v", "libx265", "-preset", "ultrafast", "-crf", "30",
            "-pix_fmt", "yuv420p10le", "-x265-params", "log-level=error",
            str(path),
        ],
    )


def make_mkv_with_subs(ffmpeg: str, source: Path, path: Path) -> None:
    srt = path.with_suffix(".srt")
    srt.write_text(
        "1\n00:00:00,000 --> 00:00:00,900\nSubtitle\n",
        encoding="utf-8",
    )
    run(
        ffmpeg,
        [
            "-i", str(source), "-i", str(srt),
            "-map", "0:v:0", "-map", "0:a:0", "-map", "1:0",
            "-c:v", "copy", "-c:a", "libmp3lame", "-b:a", "128k",
            "-c:s", "srt", str(path),
        ],
    )


def split_job(cfg, source: Path, logger: Logger):
    return run_split(
        [source],
        cfg,
        SplitOptions(
            fps=None, start=None, end=None, format="png", jpeg_quality=1,
            png_compression=3, denoise="none", tonemap=False, decode="cpu",
            scale=2, target_height=None, model="upscayl-standard-4x",
            verify_frames=False, recursive=False, force=False,
        ),
        logger,
    )[0]


def copy_frames(job) -> None:
    job.upscaled_dir.mkdir(exist_ok=True)
    for frame in sorted(job.frames_dir.glob("frame_*.png")):
        (job.upscaled_dir / frame.name).write_bytes(frame.read_bytes())


def scale_frames(ffmpeg: str, source: Path, target: Path, width: int, height: int) -> None:
    target.mkdir(exist_ok=True)
    run(
        ffmpeg,
        [
            "-framerate", "30", "-start_number", "1",
            "-i", str(source / "frame_%08d.png"),
            "-vf", f"scale={width}:{height}",
            str(target / "frame_%08d.png"),
        ],
    )


def make_trim_clip(ffmpeg: str, path: Path) -> None:
    audio = "aevalsrc=if(between(t\\,1\\,2)\\,0.5*sin(2*PI*440*t)\\,0):s=48000:d=3"
    run(
        ffmpeg,
        [
            "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=30",
            "-f", "lavfi", "-i", audio,
            "-t", "3", "-c:v", "libx264", "-preset", "ultrafast",
            "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac",
            "-b:a", "128k", "-shortest", str(path),
        ],
    )


class TestFormatsIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = find_ffmpeg()
        if cls.ffmpeg is None:
            raise unittest.SkipTest("ffmpeg not available")
        cls.ffprobe = find_ffprobe(cls.ffmpeg)
        cls.td = tempfile.TemporaryDirectory()
        cls.root = Path(cls.td.name)
        cls.logger = Logger(quiet=True)
        cls.clip = cls.root / "clip.mp4"
        cls.clip_noaudio = cls.root / "clip_noaudio.mp4"
        cls.mkv = cls.root / "clip_subs.mkv"
        cls.odd = cls.root / "odd.mkv"
        cls.tenbit = cls.root / "tenbit.mkv"
        cls.small = cls.root / "small.mp4"
        cls.trim = cls.root / "trim.mkv"
        make_clip(cls.ffmpeg, cls.clip, duration=1.0, size="160x120", fps=30)
        make_clip(cls.ffmpeg, cls.clip_noaudio, duration=1.0, size="160x120", fps=30, audio=False)
        make_clip(cls.ffmpeg, cls.small, duration=1.0, size="80x60", fps=30)
        make_mkv_with_subs(cls.ffmpeg, cls.clip, cls.mkv)
        make_odd_clip(cls.ffmpeg, cls.odd)
        make_10bit_clip(cls.ffmpeg, cls.tenbit)
        make_trim_clip(cls.ffmpeg, cls.trim)

    @classmethod
    def tearDownClass(cls):
        cls.td.cleanup()

    def config(self, name: str):
        return load_config(
            None,
            overrides={
                "ffmpeg": self.ffmpeg,
                "ffprobe": self.ffprobe,
                "work_dir": str(self.root / name),
            },
        )

    def test_odd_dimensions_are_padded(self):
        job = split_job(self.config("odd-work"), self.odd, self.logger)
        info = ffprobe_json(self.ffprobe, job.frames_dir / "frame_00000001.png")
        video = [s for s in info["streams"] if s["codec_type"] == "video"][0]
        self.assertEqual(video["width"] % 2, 0)
        self.assertEqual(video["height"] % 2, 0)
        self.assertGreaterEqual(video["width"], 321)
        self.assertGreaterEqual(video["height"], 241)

    def test_10bit_sdr_is_accepted(self):
        job = split_job(self.config("10bit-work"), self.tenbit, self.logger)
        self.assertEqual(job.get_int("frame_count"), 30)
        info = ffprobe_json(self.ffprobe, job.frames_dir / "frame_00000001.png")
        video = [s for s in info["streams"] if s["codec_type"] == "video"][0]
        self.assertEqual(video["pix_fmt"], "rgb24")

    def test_mkv_hevc_copies_mp3_and_subtitles(self):
        cfg = self.config("mkv-work")
        job = split_job(cfg, self.mkv, self.logger)
        copy_frames(job)
        output = run_assemble(
            [job],
            cfg,
            EncodeOptions(
                preset="mkv-hevc", encoder="cpu", audio="copy", subs="copy"
            ),
            self.logger,
        )[0]
        info = ffprobe_json(self.ffprobe, output)
        codecs = {stream["codec_type"]: stream["codec_name"] for stream in info["streams"]}
        self.assertEqual(codecs["video"], "hevc")
        self.assertEqual(codecs["audio"], "mp3")
        self.assertEqual(codecs["subtitle"], "subrip")

    def test_prores_pcm(self):
        cfg = self.config("prores-work")
        job = split_job(cfg, self.clip, self.logger)
        copy_frames(job)
        output = run_assemble(
            [job],
            cfg,
            EncodeOptions(
                preset="mov-prores", encoder="cpu", audio="pcm", subs="auto"
            ),
            self.logger,
        )[0]
        info = ffprobe_json(self.ffprobe, output)
        video = [s for s in info["streams"] if s["codec_type"] == "video"][0]
        audio = [s for s in info["streams"] if s["codec_type"] == "audio"][0]
        self.assertEqual(video["codec_name"], "prores")
        self.assertEqual(video["pix_fmt"], "yuv422p10le")
        self.assertTrue(audio["codec_name"].startswith("pcm_"))

    def test_mp4_hevc_aac(self):
        cfg = self.config("hevc-work")
        job = split_job(cfg, self.clip, self.logger)
        copy_frames(job)
        output = run_assemble(
            [job],
            cfg,
            EncodeOptions(
                preset="mp4-hevc", encoder="cpu", audio="aac", subs="auto"
            ),
            self.logger,
        )[0]
        info = ffprobe_json(self.ffprobe, output)
        codecs = {stream["codec_type"]: stream["codec_name"] for stream in info["streams"]}
        self.assertEqual(codecs["video"], "hevc")
        self.assertEqual(codecs["audio"], "aac")

    def test_stored_target_height_is_used_by_assemble(self):
        cfg = self.config("target-work")
        job = run_split(
            [self.small],
            cfg,
            SplitOptions(
                fps=None, start=None, end=None, format="png", jpeg_quality=1,
                png_compression=3, denoise="none", tonemap=False, decode="cpu",
                scale=None, target_height=90, model="upscayl-standard-4x",
                verify_frames=False, recursive=False, force=False,
            ),
            self.logger,
        )[0]
        scale_frames(self.ffmpeg, job.frames_dir, job.upscaled_dir, 160, 120)
        output = run_assemble(
            [job],
            cfg,
            EncodeOptions(
                preset="mp4-h264", encoder="cpu", audio="none", subs="none"
            ),
            self.logger,
        )[0]
        info = ffprobe_json(self.ffprobe, output)
        video = [s for s in info["streams"] if s["codec_type"] == "video"][0]
        self.assertEqual((video["width"], video["height"]), (120, 90))

    def test_trim_seeks_audio_to_the_range(self):
        cfg = self.config("trim-work")
        job = run_split(
            [self.trim],
            cfg,
            SplitOptions(
                fps=None, start="1", end="2", format="png", jpeg_quality=1,
                png_compression=3, denoise="none", tonemap=False, decode="cpu",
                scale=2, target_height=None, model="upscayl-standard-4x",
                verify_frames=False, recursive=False, force=False,
            ),
            self.logger,
        )[0]
        copy_frames(job)
        output = run_assemble(
            [job],
            cfg,
            EncodeOptions(
                preset="mp4-h264", encoder="cpu", audio="copy", subs="auto"
            ),
            self.logger,
        )[0]
        probe = subprocess.run(
            [
                self.ffmpeg, "-hide_banner", "-i", str(output),
                "-map", "0:a:0", "-af", "volumedetect", "-f", "null", "-",
            ],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
        )
        match = re.search(r"mean_volume:\s*(-?[0-9.]+) dB", probe.stderr)
        self.assertIsNotNone(match, probe.stderr)
        self.assertGreater(float(match.group(1)), -40.0)

    def test_no_audio(self):
        cfg = self.config("mute-work")
        job = split_job(cfg, self.clip_noaudio, self.logger)
        copy_frames(job)
        output = run_assemble(
            [job],
            cfg,
            EncodeOptions(
                preset="mp4-h264", encoder="cpu", audio="none", subs="none"
            ),
            self.logger,
        )[0]
        info = ffprobe_json(self.ffprobe, output)
        self.assertFalse(any(s["codec_type"] == "audio" for s in info["streams"]))


if __name__ == "__main__":
    unittest.main()
