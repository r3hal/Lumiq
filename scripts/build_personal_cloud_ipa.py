#!/usr/bin/env python3
"""Private Codemagic Debug build. No persistent artifacts or credential arguments."""
import argparse
from contextlib import contextmanager
from dataclasses import dataclass, field
import hashlib
import hmac
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BRANCH = "codex/focal-cloud-composition-scan"
IPA_NAME = "Focal-CloudScan-Debug-unsigned.ipa"
CONFIG = Path("LocalDeveloper/CloudComposition.local.json")
LIMIT = 131072
MESSAGES = {
    "context": "Run this workflow manually on codex/focal-cloud-composition-scan, not a tag or pull request.",
    "configuration": "Missing or invalid encrypted GEMINI_API_KEY or explicit GEMINI_MODEL. No credential value is logged.",
    "export": "Codemagic automatic export overlaps the private IPA workspace. Refusing retained artifact delivery.",
    "tracked": "Developer configuration is tracked or is not ignored by Git. Refusing to build.",
    "exists": "Private output or developer configuration already exists. Refusing to overwrite it.",
    "authorization": "Google rejected this API project's credentials or permissions (401/403). No fallback model was used.",
    "quota": "Google returned quota/rate limit 429. No retry or fallback model was used.",
    "model": "The explicitly configured model is unavailable or lacks generateContent. No replacement was selected.",
    "network": "Google verification timed out or failed HTTPS/network validation. No IPA was produced.",
    "provider": "Google service failure. Its raw response is deliberately not logged.",
    "request": "Google rejected the request. Check the API request contract and project configuration privately.",
    "response": "Google returned an invalid or oversized response. Its contents are deliberately not logged.",
    "redirect": "Google returned a redirect, which this private workflow refuses to follow.",
    "http": "Google returned an unexpected HTTP status. No IPA was produced.",
    "probe": "The configured model did not complete the structured text probe. No IPA was produced.",
    "debug": "Build settings are not Debug with DEBUG enabled and the expected executable layout.",
    "build": "Xcode or packaging failed. Raw build output is not published by this sensitive workflow.",
    "bundle": "The device bundle or IPA failed configuration, platform, executable or archive validation.",
    "download": "Private download was not acknowledged within 15 minutes. The build copy has been removed.",
    "ack": "Download hash does not match the prepared IPA. Nothing was acknowledged.",
    "cancelled": "Private build cancelled; owned sensitive files are being removed.",
}

# Diagnostic labels are application constants, never provider strings or configuration.
GOOGLE_STAGES = {"metadata": "model metadata GET", "probe": "structured text POST"}
GOOGLE_CATEGORIES = {
    "authorization": "permission", "quota": "quota", "model": "unavailable model",
    "request": "invalid request", "network": "network or timeout",
    "provider": "service failure", "response": "invalid response",
    "redirect": "redirect rejected", "http": "unexpected HTTP status",
    "probe": "invalid structured output",
}

class SafeFailure(Exception):
    def __init__(self, code, *, stage=None, status=None):
        self.code = code
        self.stage = stage if stage in GOOGLE_STAGES else None
        self.status = status if type(status) is int and 100 <= status <= 599 else None
        self.category = GOOGLE_CATEGORIES.get(code)
        message = MESSAGES[code]
        if self.stage is not None and self.category is not None:
            http = str(self.status) if self.status is not None else "not received"
            message = ("Google verification failed [stage=" + GOOGLE_STAGES[self.stage]
                       + "; HTTP " + http + "; category=" + self.category + "]. " + message)
        super().__init__(message)

@dataclass(frozen=True)
class Configuration:
    model: str
    api_key: str = field(repr=False)

    @classmethod
    def from_environment(cls, environment):
        model = environment.get("GEMINI_MODEL", "")
        key = environment.get("GEMINI_API_KEY", "")
        if (not re.fullmatch(r"gemini-[a-z0-9.-]{1,73}", model)
                or not key or len(key) >= 256 or key.startswith("REPLACE_")
                or not key.isascii() or any(ord(c) < 33 or ord(c) == 127 for c in key)):
            raise SafeFailure("configuration")
        return cls(model, key)

    def json(self):
        return {"model": self.model, "apiKey": self.api_key}

def public_environment(environment=None):
    """Never forward the credential to xcodebuild, ditto, git or their build phases."""
    result = dict(os.environ if environment is None else environment)
    result.pop("GEMINI_API_KEY", None)
    return result

def check_context(environment):
    if (environment.get("CM_TRIGGER_SOURCE") != "api"
            or environment.get("CM_BRANCH") != BRANCH
            or environment.get("CM_TAG")
            or environment.get("CM_PULL_REQUEST_NUMBER")):
        raise SafeFailure("context")

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def status_error(status, *, stage=None):
    if type(status) is not int or not 100 <= status <= 599:
        return SafeFailure("http", stage=stage)
    if status in (401, 403):
        code = "authorization"
    elif status == 429:
        code = "quota"
    elif status in (404, 410):
        code = "model"
    elif status in (408, 504):
        code = "network"
    elif 400 <= status < 500:
        code = "request"
    elif 300 <= status < 400:
        code = "redirect"
    elif 500 <= status < 600:
        code = "provider"
    else:
        code = "http"
    return SafeFailure(code, stage=stage, status=status)

class GoogleClient:
    def __init__(self, opener=None):
        self.opener = opener or urllib.request.build_opener(
            NoRedirect(), urllib.request.HTTPSHandler(context=ssl.create_default_context()))

    def request(self, configuration, method, suffix="", body=None):
        stage = {("GET", ""): "metadata", ("POST", ":generateContent"): "probe"}.get((method, suffix))
        status = None
        # Model is validated before URL construction. Credential is header-only.
        url = "https://generativelanguage.googleapis.com/v1beta/models/" + configuration.model + suffix
        request = urllib.request.Request(url, method=method,
            data=None if body is None else json.dumps(body).encode("utf-8"),
            headers={"x-goog-api-key": configuration.api_key, "Content-Type": "application/json"})
        try:
            with self.opener.open(request, timeout=20) as response:
                status = response.status
                if status != 200:
                    raise status_error(status, stage=stage)
                data = response.read(LIMIT + 1)
                if len(data) > LIMIT:
                    raise SafeFailure("response", stage=stage, status=status)
                return json.loads(data)
        except urllib.error.HTTPError as error:
            # Do not read/print the provider error body (which may echo credentials).
            raise status_error(error.code, stage=stage) from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise SafeFailure("network", stage=stage, status=status) from None
        except (ValueError, UnicodeError):
            raise SafeFailure("response", stage=stage, status=status) from None

def verify_model(configuration, client):
    metadata = client.request(configuration, "GET")
    if (not isinstance(metadata, dict) or metadata.get("name") != "models/" + configuration.model
            or not isinstance(metadata.get("supportedGenerationMethods"), list)
            or "generateContent" not in metadata["supportedGenerationMethods"]):
        raise SafeFailure("model", stage="metadata", status=200)
    # responseFormat.text.mimeType is a REST enum (APPLICATION_JSON), unlike
    # the HTTP Content-Type header and inline JPEG MIME strings.
    # One bounded text-only generation verifies this project's actual invocation
    # and the same structured-output REST format as the app. No image is uploaded.
    body = {
        "contents": [{"role": "user", "parts": [{"text":
            'Capability check only. Return the JSON object {"probe":"ok"}.'}]}],
        "generationConfig": {"candidateCount": 1, "maxOutputTokens": 1024,
            "responseFormat": {"text": {"mimeType": "APPLICATION_JSON", "schema": {
                "type": "object", "properties": {"probe": {"type": "string", "enum": ["ok"]}},
                "required": ["probe"], "additionalProperties": False}}}},
    }
    response = client.request(configuration, "POST", ":generateContent", body)
    try:
        candidates = response["candidates"]
        if len(candidates) != 1 or candidates[0]["finishReason"] != "STOP":
            raise ValueError()
        parts = [p["text"] for p in candidates[0]["content"]["parts"]
                 if p.get("thought") is not True and isinstance(p.get("text"), str)]
        if len(parts) != 1 or json.loads(parts[0]) != {"probe": "ok"}:
            raise ValueError()
    except (AttributeError, KeyError, TypeError, ValueError):
        raise SafeFailure("probe", stage="probe", status=200) from None

@contextmanager
def developer_configuration(root, configuration):
    folder = root / CONFIG.parent
    target = root / CONFIG
    if folder.is_symlink() or target.exists() or target.is_symlink():
        raise SafeFailure("exists")
    folder.mkdir(mode=0o700, exist_ok=True)
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(configuration.json(), stream)
        yield target
    finally:
        target.unlink(missing_ok=True)

@contextmanager
def private_output(root):
    parent = root / "build"
    if parent.is_symlink():
        raise SafeFailure("exists")
    parent.mkdir(exist_ok=True)
    output = parent / "private-cloud"
    # Codemagic also auto-exports CM_EXPORT_DIR independently of YAML patterns.
    exported = os.environ.get("CM_EXPORT_DIR")
    if exported:
        export_root = Path(exported).resolve()
        resolved = output.resolve()
        if resolved == export_root or export_root in resolved.parents:
            raise SafeFailure("export")
    try:
        output.mkdir(mode=0o700)
    except FileExistsError:
        raise SafeFailure("exists") from None
    try:
        yield output
    finally:
        # Only this freshly created, fixed workspace is owned by this command.
        if output.is_symlink():
            output.unlink()
        elif output.exists() and output.resolve().parent == parent.resolve():
            shutil.rmtree(output)

def run_tool(arguments, root, log_path, capture=False, timeout=1500):
    try:
        # No shell, credential arguments, inherited credential or public raw logs.
        with log_path.open("ab") as log:
            result = subprocess.run(arguments, cwd=root, env=public_environment(),
                stdout=subprocess.PIPE if capture else log, stderr=log,
                timeout=timeout, check=False)
        if result.returncode:
            raise SafeFailure("build")
        return result.stdout or b""
    except (OSError, subprocess.SubprocessError):
        raise SafeFailure("build") from None

def check_debug_settings(data):
    try:
        settings = next(e["buildSettings"] for e in json.loads(data) if e.get("target") == "Focal")
        if (settings["CONFIGURATION"] != "Debug"
                or "DEBUG" not in settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"].split()
                or settings["ENABLE_DEBUG_DYLIB"] != "NO"):
            raise ValueError()
    except (ValueError, KeyError, TypeError, StopIteration):
        raise SafeFailure("debug") from None

def check_configuration(data, expected):
    try:
        value = json.loads(data)
        if (set(value) != {"apiKey", "model"} or value["model"] != expected.model
                or not isinstance(value["apiKey"], str)
                or not hmac.compare_digest(value["apiKey"], expected.api_key)):
            raise ValueError()
    except (ValueError, TypeError, UnicodeError):
        raise SafeFailure("bundle") from None

def verify_device_app(app, configuration, architectures):
    try:
        info = plistlib.loads((app / "Info.plist").read_bytes())
        executable = info["CFBundleExecutable"]
        if ("iPhoneOS" not in info["CFBundleSupportedPlatforms"]
                or not isinstance(executable, str) or Path(executable).name != executable
                or not executable or not (app / executable).is_file()
                or "arm64" not in architectures.split()
                or not set(architectures.split()).issubset({"arm64", "arm64e"})
                or (app / "embedded.mobileprovision").exists()):
            raise ValueError()
        check_configuration((app / "CloudComposition.local.json").read_bytes(), configuration)
        return executable
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException):
        raise SafeFailure("bundle") from None

def verify_ipa(ipa, configuration, executable):
    config_path = "Payload/Focal.app/CloudComposition.local.json"
    try:
        with zipfile.ZipFile(ipa) as archive:
            names = archive.namelist()
            if (len(names) != len(set(names))
                    or any(n.startswith("/") or "\\" in n or ".." in Path(n).parts
                           or not (n == "Payload/" or n.startswith("Payload/")) for n in names)
                    or names.count(config_path) != 1
                    or not archive.getinfo("Payload/Focal.app/" + executable).external_attr >> 16 & 0o111
                    or archive.testzip() is not None):
                raise ValueError()
            check_configuration(archive.read(config_path), configuration)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile):
        raise SafeFailure("bundle") from None

def archive_and_package(root, configuration, scratch, output, runner=run_tool):
    log = scratch / "private-build.log"
    base = ["xcodebuild", "-project", "Focal.xcodeproj", "-scheme", "Focal",
        "-configuration", "Debug", "-destination", "generic/platform=iOS",
        "-derivedDataPath", str(scratch / "DerivedData"),
        "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "ENABLE_DEBUG_DYLIB=NO"]
    settings = runner(base + ["-showBuildSettings", "-json"], root, log, capture=True)
    check_debug_settings(settings)
    archive = scratch / "Focal.xcarchive"
    runner(base + ["-archivePath", str(archive), "archive"], root, log)
    app = archive / "Products/Applications/Focal.app"
    try:
        info = plistlib.loads((app / "Info.plist").read_bytes())
        executable = info["CFBundleExecutable"]
        if not isinstance(executable, str) or Path(executable).name != executable:
            raise SafeFailure("bundle")
    except (OSError, ValueError, KeyError):
        raise SafeFailure("bundle") from None
    architectures = runner(["xcrun", "lipo", "-archs", str(app / executable)],
        root, log, capture=True).decode("ascii", errors="replace")
    executable = verify_device_app(app, configuration, architectures)
    payload = scratch / "staging/Payload"
    payload.mkdir(parents=True)
    runner(["ditto", str(app), str(payload / "Focal.app")], root, log)
    ipa = output / IPA_NAME
    runner(["ditto", "-c", "-k", "--norsrc", "--keepParent", str(payload), str(ipa)], root, log)
    ipa.chmod(0o600)
    verify_ipa(ipa, configuration, executable)
    return ipa

def digest(path):
    with path.open("rb") as stream:
        value = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
        return value.hexdigest()

def acknowledge(root, downloaded_hash):
    output = root / "build/private-cloud"
    ipa = output / IPA_NAME
    if (not re.fullmatch("[0-9a-fA-F]{64}", downloaded_hash)
            or not ipa.is_file() or not hmac.compare_digest(digest(ipa), downloaded_hash.lower())):
        raise SafeFailure("ack")
    ack = output / "downloaded.sha256"
    with os.fdopen(os.open(ack, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
        stream.write(downloaded_hash.lower())

def wait_for_download(output, expected_hash, seconds=900, clock=time.monotonic, sleep=time.sleep):
    end = clock() + seconds
    ack = output / "downloaded.sha256"
    while clock() < end:
        if ack.is_file() and hmac.compare_digest(ack.read_text().strip(), expected_hash):
            return
        sleep(1)
    raise SafeFailure("download")

def build():
    check_context(os.environ)
    configuration = Configuration.from_environment(os.environ)
    # Refuse existing local work before generating anything or calling Google.
    if (ROOT / CONFIG).exists() or (ROOT / CONFIG).is_symlink():
        raise SafeFailure("exists")
    if (subprocess.run(["git", "check-ignore", "--quiet", "--", str(CONFIG)],
            cwd=ROOT, env=public_environment(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
            or subprocess.run(["git", "ls-files", "--error-unmatch", "--", str(CONFIG)],
            cwd=ROOT, env=public_environment(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0):
        raise SafeFailure("tracked")
    with private_output(ROOT) as output:
        verify_model(configuration, GoogleClient())
        print("LIVE MODEL CHECK PASSED: " + configuration.model
              + " (metadata GET + one structured text request; no image).", flush=True)
        with tempfile.TemporaryDirectory(prefix="build-", dir=output) as directory:
            with developer_configuration(ROOT, configuration):
                ipa = archive_and_package(ROOT, configuration, Path(directory), output)
        # The source config, archive, staging app, DerivedData and private log are gone.
        sha = digest(ipa)
        print("PRIVATE DEBUG IPA READY; no Codemagic artifact is published.", flush=True)
        print("SCP source: " + str(ipa), flush=True)
        print("SHA256: " + sha, flush=True)
        print("Download now over the enabled Codemagic SSH connection.", flush=True)
        print("After Windows Get-FileHash matches, acknowledge from SSH:", flush=True)
        print('cd "$CM_BUILD_DIR" && python3 scripts/build_personal_cloud_ipa.py downloaded --sha256 ' + sha, flush=True)
        print("The build copy is deleted on acknowledgement or after 15 minutes.", flush=True)
        wait_for_download(output, sha)
    print("Download acknowledged; private build files removed.", flush=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("build")
    downloaded = commands.add_parser("downloaded")
    downloaded.add_argument("--sha256", required=True)
    arguments = parser.parse_args()
    def cancelled(signum, frame):
        raise SafeFailure("cancelled")
    signal.signal(signal.SIGTERM, cancelled)
    try:
        if arguments.command == "build":
            build()
        else:
            acknowledge(ROOT, arguments.sha256)
    except SafeFailure as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("ERROR: " + MESSAGES["cancelled"], file=sys.stderr)
        return 130
    except Exception:
        # Deliberately no traceback, provider body, environment or credential repr.
        print("ERROR: Private build failed; no sensitive output is published.", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
