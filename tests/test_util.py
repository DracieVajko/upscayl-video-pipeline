import sys
import tempfile
import unittest
from pathlib import Path

from upscayl_video.errors import CommandError, ValidationError
from upscayl_video.util import (
    Logger,
    atomic_write_text,
    format_duration,
    human_bytes,
    parse_time,
    run_command,
    sanitize_job_id,
)


class TestTimeParsing(unittest.TestCase):
    def test_seconds(self):
        self.assertEqual(parse_time("90"), 90.0)

    def test_minutes_seconds(self):
        self.assertEqual(parse_time("1:30"), 90.0)

    def test_hours_minutes_seconds_with_fraction(self):
        self.assertEqual(parse_time("01:02:03.5"), 3723.5)

    def test_negative_is_rejected(self):
        with self.assertRaises(ValidationError):
            parse_time("-1")


class TestFormatting(unittest.TestCase):
    def test_format_duration(self):
        self.assertEqual(format_duration(3723.5), "01:02:03.500")

    def test_human_bytes(self):
        self.assertEqual(human_bytes(0), "0 B")
        self.assertEqual(human_bytes(1536), "1.5 KiB")
        self.assertEqual(human_bytes(10 * 1024 * 1024), "10.0 MiB")


class TestSanitizeJobId(unittest.TestCase):
    def test_windows_invalid_characters_and_spaces(self):
        self.assertEqual(sanitize_job_id("my video: final?"), "my_video_final")

    def test_unicode_is_preserved(self):
        self.assertEqual(sanitize_job_id("žluťoučký kůň"), "žluťoučký_kůň")

    def test_reserved_windows_name(self):
        self.assertEqual(sanitize_job_id("CON"), "CON_")

    def test_empty_falls_back(self):
        self.assertEqual(sanitize_job_id("  ...  "), "video")


class TestAtomicWrite(unittest.TestCase):
    def test_replaces_content_without_leaving_temp_file(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "job.txt"
            atomic_write_text(path, "a=1\n")
            atomic_write_text(path, "a=2\n")
            self.assertEqual(path.read_text(encoding="utf-8"), "a=2\n")
            self.assertEqual(list(Path(td).iterdir()), [path])


class TestRunCommand(unittest.TestCase):
    def test_captures_stdout(self):
        logger = Logger(quiet=True)
        result = run_command(
            [sys.executable, "-c", "print('hello')"],
            logger=logger,
        )
        self.assertEqual(result.stdout.strip(), "hello")

    def test_nonzero_raises_command_error(self):
        logger = Logger(quiet=True)
        with self.assertRaises(CommandError):
            run_command(
                [sys.executable, "-c", "import sys; sys.exit(7)"],
                logger=logger,
            )


if __name__ == "__main__":
    unittest.main()
