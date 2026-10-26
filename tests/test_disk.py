import tempfile
import unittest
from pathlib import Path

from upscayl_video.disk import DiskEstimate, check_estimate, estimate_disk, free_bytes
from upscayl_video.errors import DiskSpaceError
from upscayl_video.util import Logger


class TestEstimate(unittest.TestCase):
    def test_math(self):
        est = estimate_disk(1000, 100, 2, margin_bytes=0)
        self.assertEqual(est.frames_bytes, 115000)
        self.assertEqual(est.upscaled_bytes, 460000)
        self.assertEqual(est.total_bytes, 575000)

    def test_free_space_check(self):
        with tempfile.TemporaryDirectory() as td:
            self.assertGreater(free_bytes(Path(td)), 0)

    def test_min_free_floor_raises(self):
        est = DiskEstimate(1000, 100, 100, 100, 200, free_bytes=5 * 1024**3 + 100, fits=True)
        with self.assertRaises(DiskSpaceError):
            check_estimate(est, min_free_gb=5, max_work_gb=40, logger=Logger(quiet=True))

    def test_over_cap_only_warns(self):
        est = DiskEstimate(1000, 100, 100, 100, 50 * 1024**3, free_bytes=100 * 1024**3, fits=True)
        # Does not raise; the logger warning is not asserted here.
        check_estimate(est, min_free_gb=5, max_work_gb=40, logger=Logger(quiet=True))


if __name__ == "__main__":
    unittest.main()
