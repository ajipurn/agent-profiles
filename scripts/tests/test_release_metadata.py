import base64
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_metadata import load_config, bundle_values


class ReleaseMetadataTests(unittest.TestCase):
    def config(self, **overrides):
        return dict(version='1.1.0', build=2, repository='owner/app',
                    sparkle_public_key=base64.b64encode(bytes(range(32))).decode(), **{}) | overrides

    def load(self, config, require_key=True):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder, 'release.json')
            path.write_text(json.dumps(config))
            return load_config(path, require_key=require_key)

    def test_stable_github_update_url_and_signing_settings(self):
        info = bundle_values(self.load(self.config()))
        self.assertEqual(info['SUFeedURL'], 'https://github.com/owner/app/releases/latest/download/appcast.xml')
        self.assertEqual(info['CFBundleVersion'], '2')
        self.assertTrue(info['SUVerifyUpdateBeforeExtraction'])
        self.assertTrue(info['SURequireSignedFeed'])
        self.assertFalse(info['SUEnableSystemProfiling'])
        self.assertFalse(info['SUAutomaticallyUpdate'])

    def test_release_refuses_missing_or_invalid_public_key(self):
        for key in ['', 'not-base64', base64.b64encode(b'short').decode()]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.load(self.config(sparkle_public_key=key))

    def test_development_can_be_configured_before_key_creation(self):
        self.assertEqual(self.load(self.config(sparkle_public_key=''), require_key=False)['sparkle_public_key'], '')

    def test_rejects_unsafe_repository_and_invalid_version(self):
        for repo in ['https://github.com/owner/app', 'owner/app/extra', 'owner/app?token=value', 'owner/app name']:
            with self.subTest(repo=repo), self.assertRaises(ValueError):
                self.load(self.config(repository=repo))
        for version in ['v1.0.0', '1.0', '1.0.0-beta', '1.0.0\nother']:
            with self.subTest(version=version), self.assertRaises(ValueError):
                self.load(self.config(version=version))

    def test_rejects_zero_negative_boolean_or_noninteger_builds(self):
        for build in [0, -1, True, '2', 1.5]:
            with self.subTest(build=build), self.assertRaises(ValueError):
                self.load(self.config(build=build))


if __name__ == '__main__':
    unittest.main()
