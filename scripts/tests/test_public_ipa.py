import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from package_public_ipa import package, validate, UnsafePackage


class PublicIPATests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        self.app = self.root/"archive/Focal.app"; self.app.mkdir(parents=True)
        (self.app/"Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable":"Focal","CFBundleIdentifier":"com.example.focal"}))
        (self.app/"Focal").write_bytes(b"mock-executable-no-credential"); (self.app/"Focal").chmod(0o755)
        self.output = self.root/"build/Focal-unsigned.ipa"
        self.env = patch.dict(os.environ, {"GEMINI_API_KEY":""}); self.env.start()
    def tearDown(self):
        self.env.stop(); self.tmp.cleanup()
    def make(self): package(self.app, self.output, root=self.root)
    def assertRejected(self):
        with self.assertRaises(UnsafePackage): self.make()
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.output.parent.glob(".public-ipa-staging-*")))
    def test_safe_release_or_debug_bundle_is_downloadable_payload(self):
        self.make(); validate(self.output)
        with zipfile.ZipFile(self.output) as archive:
            self.assertIn("Payload/Focal.app/Focal", archive.namelist())
    def test_private_developer_configuration_never_reaches_artifact(self):
        (self.app/"CloudComposition.local.json").write_text('{"apiKey":"fixture-not-real"}')
        self.assertRejected()
    def test_refresh_and_device_tokens_in_json_are_rejected(self):
        for key in ["refresh_token", "client_secret", "deviceToken", "accessToken"]:
            with self.subTest(key=key):
                (self.app/"configuration.json").write_text('{"nested":{"'+key+'":"fixture-not-real"}}')
                self.assertRejected()
    def test_google_key_in_binary_is_rejected_without_echoing_it(self):
        (self.app/"Focal").write_bytes(b"prefix-"+b"AIza"+b"x"*35)
        self.assertRejected()
    def test_oauth_refresh_token_in_binary_is_rejected(self):
        (self.app/"Focal").write_bytes(b"1//"+b"x"*35)
        self.assertRejected()
    def test_secret_environment_refuses_public_packaging(self):
        with patch.dict(os.environ,{"GEMINI_API_KEY":"fixture-not-real"}): self.assertRejected()
    def test_local_private_configuration_refuses_public_build(self):
        config = self.root/"LocalDeveloper/CloudComposition.local.json"; config.parent.mkdir(); config.write_text("{}")
        self.assertRejected()
    def test_symlink_is_not_followed_into_other_files(self):
        (self.root/"private.txt").write_text("fixture"); (self.app/"linked").symlink_to(self.root/"private.txt")
        self.assertRejected()
    def test_missing_or_nonexecutable_binary_is_rejected(self):
        (self.app/"Focal").chmod(0o644); self.assertRejected()
    def test_existing_output_is_not_overwritten(self):
        self.make(); original = self.output.read_bytes()
        with self.assertRaises(UnsafePackage): self.make()
        self.assertEqual(original,self.output.read_bytes())
    def test_malformed_or_traversal_archive_is_rejected(self):
        self.output.parent.mkdir()
        with zipfile.ZipFile(self.output,"w") as archive: archive.writestr("Payload/Focal.app/../../secret",b"fixture")
        with self.assertRaises(UnsafePackage): validate(self.output)
    def test_duplicate_archive_entries_are_rejected(self):
        self.make()
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            with zipfile.ZipFile(self.output,"a") as archive: archive.writestr("Payload/Focal.app/Info.plist",b"fixture")
        with self.assertRaises(UnsafePackage): validate(self.output)


if __name__ == "__main__": unittest.main()
