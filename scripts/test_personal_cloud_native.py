#!/usr/bin/env python3
"""macOS CI smoke: real Debug device archive/IPA, fake credential, no network."""
import os
from pathlib import Path
import tempfile
from build_personal_cloud_ipa import (
    ROOT, CONFIG, Configuration, archive_and_package, developer_configuration, private_output)

def main():
    if os.environ.get("GEMINI_API_KEY"):
        raise RuntimeError("Packaging smoke test refuses real credential environments")
    fixture = Configuration("gemini-3.8-flash", "CI-FIXTURE-NOT-A-REAL-KEY")
    with private_output(ROOT) as output:
        with tempfile.TemporaryDirectory(prefix="smoke-", dir=output) as scratch:
            with developer_configuration(ROOT, fixture):
                ipa = archive_and_package(ROOT, fixture, Path(scratch), output)
                assert ipa.is_file()
        assert not (ROOT / CONFIG).exists()
    assert not (ROOT / "build/private-cloud").exists()
    print("PASS: real arm64 Debug archive and IPA; matching fixture configuration; executable ZIP layout; private files cleaned. No provider call or real key used.")

if __name__ == "__main__":
    main()
