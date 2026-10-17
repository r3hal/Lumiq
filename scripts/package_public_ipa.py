#!/usr/bin/env python3
"""Package only a validated, non-secret app; publish by atomic rename last.

This is a conservative distribution guard, not a proof that arbitrary unknown
secret formats can be recognized. Public CI must have no secret groups/config.
"""
import argparse
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SECRET_PATTERNS = [rb"AIza[0-9A-Za-z_-]{30,}", rb"ya29\.[0-9A-Za-z_-]{20,}",
                   rb"1//[0-9A-Za-z_-]{20,}", rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"]
FORBIDDEN = {"cloudcomposition.local.json", ".env", "credentials.json", "token.json", "service-account.json"}


class UnsafePackage(ValueError):
    pass


def validate(ipa: Path):
    try:
        with zipfile.ZipFile(ipa) as archive:
            entries = archive.infolist()
            if len(entries) > 10000 or sum(x.file_size for x in entries) > 1024**3:
                raise UnsafePackage()
            names = [x.filename for x in entries]
            if len(names) != len(set(names)):
                raise UnsafePackage()
            for entry in entries:
                path = PurePosixPath(entry.filename)
                if (path.is_absolute() or ".." in path.parts or "\\" in entry.filename
                        or not entry.filename.startswith("Payload/Focal.app/")
                        or stat.S_ISLNK(entry.external_attr >> 16) or entry.file_size > 128*1024**2
                        or path.name.lower() in FORBIDDEN or "localdeveloper" in entry.filename.lower()):
                    raise UnsafePackage()
                if entry.is_dir():
                    continue
                content = archive.read(entry)
                if any(re.search(pattern, content) for pattern in SECRET_PATTERNS):
                    raise UnsafePackage()
                if path.suffix.lower() in (".json", ".plist"):
                    # Secret field names plus nonempty JSON/plist strings are
                    # forbidden; Swift code may legitimately name such fields.
                    import json
                    try:
                        value = plistlib.loads(content) if path.suffix.lower() == ".plist" else json.loads(content)
                    except (ValueError, TypeError, plistlib.InvalidFileException):
                        value = None
                    def secret(item):
                        if isinstance(item, dict):
                            for key, value in item.items():
                                if str(key).lower().replace("_", "") in {"apikey", "clientsecret", "refreshtoken", "accesstoken", "privatekey", "devicetoken"} and isinstance(value, str) and value:
                                    return True
                                if secret(value): return True
                        if isinstance(item, list): return any(secret(v) for v in item)
                        return False
                    if secret(value):
                        raise UnsafePackage()
            info = plistlib.loads(archive.read("Payload/Focal.app/Info.plist"))
            executable = info.get("CFBundleExecutable")
            if (not isinstance(executable, str) or "/" in executable or executable in ("", ".", "..")
                    or "Payload/Focal.app/"+executable not in names):
                raise UnsafePackage()
            binary = archive.getinfo("Payload/Focal.app/"+executable)
            if not (binary.external_attr >> 16) & stat.S_IXUSR:
                raise UnsafePackage()
    except (OSError, KeyError, ValueError, zipfile.BadZipFile, RuntimeError):
        raise UnsafePackage("IPA rejected by the public-artifact guard; no artifact was published") from None


def package(app: Path, output: Path, *, root: Path = ROOT):
    if os.environ.get("GEMINI_API_KEY") or (root/"LocalDeveloper/CloudComposition.local.json").exists():
        raise UnsafePackage("Public builds must not have developer credentials configured")
    if not app.is_dir() or app.is_symlink() or app.name != "Focal.app" or output.exists():
        raise UnsafePackage("Use a fresh output path and an archived Focal.app")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Exact artifact patterns never include this private staging directory.
    with tempfile.TemporaryDirectory(prefix=".public-ipa-staging-", dir=output.parent) as scratch:
        staged = Path(scratch)/"candidate.zip"
        with zipfile.ZipFile(staged, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for path in sorted(app.rglob("*")):
                if path.is_symlink():
                    raise UnsafePackage("Symlink in app bundle; nothing published")
                if path.is_file():
                    archive.write(path, "Payload/Focal.app/"+path.relative_to(app).as_posix())
        validate(staged)
        os.replace(staged, output)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package(args.app, args.output)
    print("PASS: non-secret unsigned IPA validated and published to the configured artifact path.")


if __name__ == "__main__":
    main()
