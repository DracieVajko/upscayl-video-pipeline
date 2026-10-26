import unittest

from upscayl_video.progress import Progress, format_eta


class TestProgress(unittest.TestCase):
    def test_eta(self):
        progress = Progress("upscale", 100)
        progress._started -= 10
        progress.update(20)
        self.assertAlmostEqual(progress.rate, 2.0, places=1)
        self.assertAlmostEqual(progress.eta_seconds, 40.0, delta=2.0)
        self.assertIn("20/100", progress.line())

    def test_format_eta(self):
        self.assertEqual(format_eta(0), "00:00:00")
        self.assertEqual(format_eta(3723), "01:02:03")


if __name__ == "__main__":
    unittest.main()
