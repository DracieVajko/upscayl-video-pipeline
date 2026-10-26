import unittest
from unittest.mock import patch

from upscayl_video.menu import run_menu
from upscayl_video.util import Logger


class TestMenu(unittest.TestCase):
    def test_exit_choice(self):
        with patch("builtins.input", side_effect=["9"]):
            self.assertEqual(run_menu(None, Logger(quiet=True)), 0)

    def test_invalid_then_exit(self):
        with patch("builtins.input", side_effect=["99", "9"]):
            self.assertEqual(run_menu(None, Logger(quiet=True)), 0)


if __name__ == "__main__":
    unittest.main()
