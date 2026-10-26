import tempfile
import time
import unittest
from pathlib import Path

from upscayl_video.errors import ValidationError
from upscayl_video.job import Job, find_jobs, read_kv, write_kv
from upscayl_video.util import Logger
from tests.factories import make_media_info


class TestKvFiles(unittest.TestCase):
    def test_round_trip_preserves_equals_and_spaces(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "job.txt"
            write_kv(path, {"source": "C:/a b/c=d.mp4", "scale": "2"})
            data = read_kv(path)
            self.assertEqual(data["source"], "C:/a b/c=d.mp4")
            self.assertEqual(data["scale"], "2")


class TestJob(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.work = Path(self.td.name) / "work"
        self.source = Path(self.td.name) / "my video.mp4"
        self.source.write_bytes(b"fake video")
        self.logger = Logger(quiet=True)

    def tearDown(self):
        self.td.cleanup()

    def test_create_and_reopen_same_source(self):
        first = Job.create_or_open(self.work, self.source, self.logger)
        first.update_from_media(make_media_info(self.source))
        first.save()
        second = Job.create_or_open(self.work, self.source, self.logger)
        self.assertEqual(first.path, second.path)
        self.assertEqual(second.get("source"), str(self.source.resolve()))

    def test_same_stem_from_other_directory_gets_suffix(self):
        other_dir = Path(self.td.name) / "other"
        other_dir.mkdir()
        other = other_dir / "my video.mp4"
        other.write_bytes(b"other")
        first = Job.create_or_open(self.work, self.source, self.logger)
        second = Job.create_or_open(self.work, other, self.logger)
        self.assertNotEqual(first.path, second.path)
        self.assertTrue(second.path.name.endswith("_2"))

    def test_unknown_keys_are_preserved(self):
        first = Job.create_or_open(self.work, self.source, self.logger)
        first.set("future_key", "value")
        first.save()
        first.set("scale", "2")
        first.save()
        self.assertEqual(Job.load(first.path).get("future_key"), "value")

    def test_markers(self):
        job = Job.create_or_open(self.work, self.source, self.logger)
        self.assertFalse(job.is_done("split"))
        job.mark_done("split")
        self.assertTrue(job.is_done("split"))
        job.clear_stage("split")
        self.assertFalse(job.is_done("split"))

    def test_source_changed(self):
        job = Job.create_or_open(self.work, self.source, self.logger)
        job.update_from_media(make_media_info(self.source))
        job.save()
        time.sleep(0.01)
        self.source.write_bytes(b"changed content")
        self.assertTrue(job.source_changed())

    def test_find_jobs(self):
        job = Job.create_or_open(self.work, self.source, self.logger)
        job.save()
        self.assertEqual([j.path for j in find_jobs(self.work)], [job.path])

    def test_invalid_job_folder_is_rejected(self):
        bad = Path(self.td.name) / "bad"
        bad.mkdir()
        with self.assertRaises(ValidationError):
            Job.load(bad)


if __name__ == "__main__":
    unittest.main()
