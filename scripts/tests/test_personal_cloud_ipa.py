"""Portable regression tests. Every credential and provider response is a fixture."""
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest import mock
import urllib.error
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_personal_cloud_ipa as build

FIXTURE = build.Configuration("gemini-3.8-flash", "CI-FIXTURE-NOT-A-REAL-KEY")
METADATA = {"name": "models/gemini-3.8-flash", "supportedGenerationMethods": ["generateContent"]}
PROBE = {"candidates": [{"finishReason": "STOP",
    "content": {"parts": [{"text": '{"probe":"ok"}'}]}}]}

class Client:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def request(self, configuration, method, suffix="", body=None):
        self.requests.append((configuration.model, method, suffix, body))
        value = self.responses.pop(0)
        if isinstance(value, Exception):
            raise value
        return value

class Response:
    status = 200
    def __init__(self, body):
        self.body = body
        self.read_limit = None
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def read(self, limit):
        self.read_limit = limit
        return self.body[:limit]

class PersonalCloudBuildTests(unittest.TestCase):
    def failure(self, code, function, *args):
        with self.assertRaises(build.SafeFailure) as raised:
            function(*args)
        self.assertEqual(raised.exception.code, code)
        self.assertNotIn(FIXTURE.api_key, str(raised.exception))

    def test_configuration_uses_exact_existing_schema_and_hides_repr(self):
        cfg = build.Configuration.from_environment(
            {"GEMINI_MODEL": FIXTURE.model, "GEMINI_API_KEY": FIXTURE.api_key})
        self.assertEqual(cfg.json(), {"model": FIXTURE.model, "apiKey": FIXTURE.api_key})
        self.assertNotIn(FIXTURE.api_key, repr(cfg))

    def test_missing_placeholder_controls_and_url_model_injection_rejected(self):
        for key in ["", "REPLACE_LOCALLY_DO_NOT_COMMIT", "secret\nheader", " leading-space", "é"]:
            self.failure("configuration", build.Configuration.from_environment,
                {"GEMINI_MODEL": FIXTURE.model, "GEMINI_API_KEY": key})
        for model in ["", "../secret", "gemini-x?key=secret", "gemini-3.8-flash/other"]:
            self.failure("configuration", build.Configuration.from_environment,
                {"GEMINI_MODEL": model, "GEMINI_API_KEY": FIXTURE.api_key})

    def test_secret_not_forwarded_to_child_tools(self):
        child = build.public_environment({"GEMINI_API_KEY": FIXTURE.api_key,
            "PATH": "/usr/bin", "GEMINI_MODEL": FIXTURE.model})
        self.assertNotIn("GEMINI_API_KEY", child)
        self.assertEqual(child["PATH"], "/usr/bin")

    def test_manual_branch_context_excludes_main_tags_and_pull_requests(self):
        build.check_context({"CM_BRANCH": build.BRANCH})
        for env in [{"CM_BRANCH": "main"}, {"CM_BRANCH": build.BRANCH, "CM_TAG": "test"},
                    {"CM_BRANCH": build.BRANCH, "CM_PULL_REQUEST_NUMBER": "42"}, {}]:
            self.failure("context", build.check_context, env)

    def test_successful_live_probe_uses_same_model_and_no_images(self):
        client = Client([METADATA, PROBE])
        build.verify_model(FIXTURE, client)
        self.assertEqual([(r[0], r[1], r[2]) for r in client.requests],
            [(FIXTURE.model, "GET", ""), (FIXTURE.model, "POST", ":generateContent")])
        body = client.requests[1][3]
        self.assertEqual(len(body["contents"][0]["parts"]), 1)
        self.assertEqual(body["generationConfig"]["responseFormat"]["text"]["mimeType"], "application/json")
        self.assertNotIn("inlineData", json.dumps(body))
        self.assertNotIn(FIXTURE.api_key, json.dumps(body))

    def test_wrong_model_or_capability_never_generates_or_falls_back(self):
        for meta in [{"name": "models/other", "supportedGenerationMethods": ["generateContent"]},
                     {"name": "models/" + FIXTURE.model, "supportedGenerationMethods": ["embedContent"]},
                     {"name": "models/" + FIXTURE.model, "supportedGenerationMethods": None}]:
            client = Client([meta])
            self.failure("model", build.verify_model, FIXTURE, client)
            self.assertEqual(len(client.requests), 1)

    def test_quota_auth_model_timeout_stop_without_retry(self):
        for status, expected in [(429, "quota"), (401, "authorization"), (403, "authorization"),
                                 (404, "model"), (504, "network"), (503, "provider")]:
            client = Client([METADATA, build.status_error(status)])
            self.failure(expected, build.verify_model, FIXTURE, client)
            self.assertEqual(len(client.requests), 2)

    def test_invalid_truncated_or_blocked_probe_is_not_live_success(self):
        for response in [{}, {"candidates": []},
            {"candidates": [{"finishReason": "MAX_TOKENS", "content": {"parts": []}}]},
            {"candidates": [{"finishReason": "STOP", "content": {"parts": [{"text": '{"ready":true}'}]}}]}]:
            self.failure("probe", build.verify_model, FIXTURE, Client([METADATA, response]))

    def test_http_has_https_header_key_timeout_and_bounded_bytes(self):
        response = Response(json.dumps(METADATA).encode())
        opener = mock.Mock()
        opener.open.return_value = response
        result = build.GoogleClient(opener).request(FIXTURE, "GET")
        request = opener.open.call_args.args[0]
        self.assertEqual(result, METADATA)
        self.assertTrue(request.full_url.startswith("https://generativelanguage.googleapis.com/"))
        self.assertNotIn(FIXTURE.api_key, request.full_url)
        self.assertEqual(request.get_header("X-goog-api-key"), FIXTURE.api_key)
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 20)
        self.assertEqual(response.read_limit, build.LIMIT + 1)

    def test_provider_error_body_and_credentials_never_surface(self):
        for status, expected in [(403, "authorization"), (429, "quota"), (404, "model")]:
            opener = mock.Mock()
            opener.open.side_effect = urllib.error.HTTPError("https://provider.invalid", status,
                FIXTURE.api_key, {}, io.BytesIO(FIXTURE.api_key.encode()))
            self.failure(expected, build.GoogleClient(opener).request, FIXTURE, "GET")
            self.assertEqual(opener.open.call_count, 1)

    def test_network_bad_json_oversize_and_redirect_fail_closed(self):
        opener = mock.Mock()
        opener.open.side_effect = urllib.error.URLError(FIXTURE.api_key)
        self.failure("network", build.GoogleClient(opener).request, FIXTURE, "GET")
        for data in [b"broken", b" " * (build.LIMIT + 1)]:
            opener = mock.Mock()
            opener.open.return_value = Response(data)
            self.failure("provider", build.GoogleClient(opener).request, FIXTURE, "GET")
        self.assertIsNone(build.NoRedirect().redirect_request(None, None, 302, "", {}, "https://evil.invalid"))

    def test_generated_configuration_private_permissions_and_cleanup(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with build.developer_configuration(root, FIXTURE) as target:
                self.assertEqual(json.loads(target.read_text()), FIXTURE.json())
                if os.name != "nt":
                    self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertFalse(target.exists())

    def test_existing_developer_work_is_not_overwritten_or_deleted(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            target = root / build.CONFIG
            target.parent.mkdir()
            target.write_text("existing developer work")
            with self.assertRaises(build.SafeFailure):
                with build.developer_configuration(root, FIXTURE):
                    self.fail("Existing configuration must not be replaced")
            self.assertEqual(target.read_text(), "existing developer work")

    @unittest.skipIf(os.name == "nt", "Symlink permission differs on Windows")
    def test_symlink_configuration_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            outside = root / "outside"
            outside.mkdir()
            (root / "LocalDeveloper").symlink_to(outside, target_is_directory=True)
            with self.assertRaises(build.SafeFailure):
                with build.developer_configuration(root, FIXTURE):
                    self.fail("Symlink must not be followed")
            self.assertEqual(list(outside.iterdir()), [])

    def test_cancellation_and_failure_remove_owned_configuration(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with self.assertRaises(build.SafeFailure):
                with build.developer_configuration(root, FIXTURE):
                    raise build.SafeFailure("cancelled")
            self.assertFalse((root / build.CONFIG).exists())

    def test_private_output_is_removed_on_success_failure_and_timeout(self):
        for error in [None, "build", "download", "cancelled"]:
            with tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                try:
                    with build.private_output(root) as output:
                        (output / build.IPA_NAME).write_bytes(b"sensitive fixture")
                        if error:
                            raise build.SafeFailure(error)
                except build.SafeFailure:
                    pass
                self.assertFalse((root / "build/private-cloud").exists())

    def test_private_output_never_deletes_existing_work(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            output = root / "build/private-cloud"
            output.mkdir(parents=True)
            original = output / "user-file"
            original.write_text("keep")
            with self.assertRaises(build.SafeFailure):
                with build.private_output(root):
                    self.fail("Existing directory must not be used")
            self.assertEqual(original.read_text(), "keep")

    def test_release_or_missing_debug_condition_is_rejected(self):
        valid = {"CONFIGURATION": "Debug", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
                 "ENABLE_DEBUG_DYLIB": "NO"}
        build.check_debug_settings(json.dumps([{"target": "Focal", "buildSettings": valid}]))
        for name, value in [("CONFIGURATION", "Release"),
                            ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "FOCAL_EVALUATION"),
                            ("ENABLE_DEBUG_DYLIB", "YES")]:
            altered = dict(valid, **{name: value})
            self.failure("debug", build.check_debug_settings,
                json.dumps([{"target": "Focal", "buildSettings": altered}]))

    def make_app(self, root):
        app = root / "Focal.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Focal", "CFBundleSupportedPlatforms": ["iPhoneOS"]}))
        (app / "Focal").write_bytes(b"fixture executable")
        (app / "Focal").chmod(0o755)
        (app / "CloudComposition.local.json").write_text(json.dumps(FIXTURE.json()))
        return app

    def test_device_bundle_requires_matching_config_and_arm64(self):
        with tempfile.TemporaryDirectory() as folder:
            app = self.make_app(Path(folder))
            self.assertEqual(build.verify_device_app(app, FIXTURE, "arm64"), "Focal")
            self.failure("bundle", build.verify_device_app, app, FIXTURE, "x86_64")
            self.failure("bundle", build.verify_device_app, app, FIXTURE, "arm64 x86_64")
            (app / "CloudComposition.local.json").write_text(json.dumps(
                {"model": "gemini-other", "apiKey": FIXTURE.api_key}))
            self.failure("bundle", build.verify_device_app, app, FIXTURE, "arm64")

    def test_simulator_and_unexpected_provisioning_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            app = self.make_app(Path(folder))
            info = plistlib.loads((app / "Info.plist").read_bytes())
            info["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            self.failure("bundle", build.verify_device_app, app, FIXTURE, "arm64")
            info["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            (app / "embedded.mobileprovision").touch()
            self.failure("bundle", build.verify_device_app, app, FIXTURE, "arm64")

    def ipa(self, path, extra=None, executable=True, config=None):
        with zipfile.ZipFile(path, "w") as archive:
            entry = zipfile.ZipInfo("Payload/Focal.app/Focal")
            entry.external_attr = (0o100755 if executable else 0o100644) << 16
            archive.writestr(entry, b"fixture executable")
            archive.writestr("Payload/Focal.app/CloudComposition.local.json",
                            json.dumps(FIXTURE.json() if config is None else config))
            if extra:
                archive.writestr(extra, b"unexpected")

    def test_ipa_structure_preserves_executable_and_rejects_path_or_secret_spill(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fixture.ipa"
            self.ipa(path)
            build.verify_ipa(path, FIXTURE, "Focal")
            for extra in ["../escape", "LocalDeveloper/CloudComposition.local.json", "/absolute"]:
                self.ipa(path, extra=extra)
                self.failure("bundle", build.verify_ipa, path, FIXTURE, "Focal")
            self.ipa(path, executable=False)
            self.failure("bundle", build.verify_ipa, path, FIXTURE, "Focal")

    def test_ipa_missing_or_different_credential_is_rejected_without_disclosure(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fixture.ipa"
            for config in [{}, {"apiKey": "different", "model": FIXTURE.model},
                           dict(FIXTURE.json(), extra=True)]:
                self.ipa(path, config=config)
                self.failure("bundle", build.verify_ipa, path, FIXTURE, "Focal")

    def test_hash_acknowledgement_and_deadline(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with build.private_output(root) as output:
                ipa = output / build.IPA_NAME
                ipa.write_bytes(b"fixture")
                expected = build.digest(ipa)
                self.failure("ack", build.acknowledge, root, "0" * 64)
                build.acknowledge(root, expected.upper())
                build.wait_for_download(output, expected, seconds=1)
                (output / "downloaded.sha256").unlink()
                ticks = [0]
                def advance(seconds): ticks[0] += seconds
                with self.assertRaises(build.SafeFailure) as raised:
                    build.wait_for_download(output, expected, seconds=3,
                        clock=lambda: ticks[0], sleep=advance)
                self.assertEqual(raised.exception.code, "download")
            self.assertFalse(ipa.exists())

    def test_cli_failure_never_prints_exception_or_environment(self):
        stderr = io.StringIO()
        with mock.patch.object(sys, "argv", ["build_personal_cloud_ipa.py", "build"]), \
             mock.patch.object(build, "build", side_effect=RuntimeError(FIXTURE.api_key)), \
             contextlib.redirect_stderr(stderr):
            self.assertEqual(build.main(), 1)
        self.assertNotIn(FIXTURE.api_key, stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())

if __name__ == "__main__":
    unittest.main()
