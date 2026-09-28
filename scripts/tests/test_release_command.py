import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release import next_version


class ReleaseVersionTests(unittest.TestCase):
    def test_default_patch(self):
        self.assertEqual(next_version('1.1.9', ''), '1.1.10')

    def test_bump_resets_lower_components(self):
        for bump, expected in [('major', '2.0.0'), ('minor', '1.3.0'), ('patch', '1.2.10')]:
            with self.subTest(bump=bump):
                self.assertEqual(next_version('1.2.9', '', bump), expected)

    def test_rejects_ambiguous_or_unknown_bump(self):
        with self.assertRaises(ValueError):
            next_version('1.1.0', '1.2.0', 'minor')
        with self.assertRaises(ValueError):
            next_version('1.1.0', '', 'feature')

    def test_explicit_minor_and_resume(self):
        self.assertEqual(next_version('1.1.0', '1.2.0'), '1.2.0')
        self.assertEqual(next_version('1.2.0', '1.2.0'), '1.2.0')

    def test_invalid_or_older(self):
        for version in ['1.0.9', 'v1.2.0', '1.2', '01.2.0', '1.2.0-rc1']:
            with self.subTest(version=version), self.assertRaises(ValueError):
                next_version('1.1.0', version)
