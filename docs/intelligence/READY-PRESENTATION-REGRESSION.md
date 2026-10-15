# Focal 2.11.1 / build 38 — verified scene READY without weakening object checks

## Root cause

Build 37 added a presentation shortcut for landscapes without an object box. It accepted any unconfirmed object reading whose state and guidance message said READY. That incorrectly promoted both a low-confidence object and a null object rectangle to READY.

The original `CameraDesignStateTests.testReadyRequiresBoundsConfidenceAndFinishedFraming` correctly rejected those cases. Its two assertions failed in the supplied Codemagic run. The test was not part of the earlier portable subset, so those failures escaped the build-37 local checks. The native log shows compilation succeeded and 607 tests executed; it does not show a passing test suite or a completed IPA archive.

## Targeted correction

- Add `CompositionReading.sceneFrameVerified`, defaulting to false on fresh readings.
- Populate it in the camera service only when the existing director reports `currentFrameVerified` and the selected shot is a whole-scene anchor.
- The no-object READY presentation now additionally requires that explicit flag and a completed `.framed` phase. A READY message, label or presentation status alone cannot supply verification.
- Leave object rectangle/confidence checks and the original failing test assertions intact. Existing scene eligibility, real zoom verification, manual zoom continuity, capture, autofocus and Sony code are not changed.
- Update the positive outdoor presentation fixture to include actual scene-verification state rather than relying on a READY message alone.
- Add native regressions for verified whole-scene presentation across unfinished/recovery/off phases and for a READY message that has no scene verification.
- Extend the portable runner with the original design-state tests and exact pure layout/aspect declarations. Only the Vision-backed tracker method and separate Apple-observable settings class are excluded from that file; the original failing test runs unchanged.

## Evidence

Using a saved pre-fix source snapshot with the expanded portable test selection reproduced **328 tests with two assertion failures**, both in the original object-readiness test. With the correction and two added cases, **330 portable XCTest cases pass with zero failures**. This includes positive whole-scene READY and negative low-confidence/missing-object cases.

All **135 Swift sources pass frontend syntax parsing**. Deterministic project/structure checks register **609 native XCTest functions** and verify the controller-to-reading scene flag wiring. `Focal/Sony` sources remain unchanged.

The initial local reproduction and fixed runs exhausted the temporary filesystem before tests could execute. After removing only old generated SwiftPM scratch directories, both saved source snapshots were rebuilt and the before/after runs completed. That infrastructure failure is separate from the app's two READY assertion failures.

Xcode is unavailable in this workspace (`xcodebuild`: command not found, exit 127). The new native build, all 609 native tests, IPA archive and physical iPhone behavior still require Codemagic/device verification. The portable tests do not execute AVFoundation, Vision or SwiftUI itself.

## Changed files

- `Focal/Composition/CompositionEngine.swift`: explicit verified-scene reading field; no engine algorithm change.
- `Focal/Camera/CameraController.swift`: copy actual director scene verification into the reading.
- `Focal/Camera/CameraGuidanceCard.swift`: require that verification for scene-only READY.
- `FocalTests/CameraDesignStateTests.swift`: two new negative/positive presentation tests; original assertions unchanged.
- `FocalTests/OutdoorGuidanceTests.swift`: positive scene fixture now includes explicit verification.
- `scripts/test_framing_portable.py`: include the previously omitted original design-state tests.
- `scripts/validate_structure.py`: test count and explicit production wiring checks.
- `scripts/generate_project.py`, `Focal.xcodeproj/project.pbxproj`: version 2.11.1 / build 38.
- `README.md`, `VALIDATION.txt`, the build-37 report and this report: corrected behavior and validation scope.

Run Codemagic `ios-sideload` on latest `main`. Confirm both the original object-readiness test and the new scene cases pass, then check a weak/lost subject does not show READY while a genuinely verified wide scene still can. The broader [build-37 forest/zoom device checklist](FOREST-GUIDANCE-CONTINUITY.md#physical-iphone-16-pro-max-acceptance-before-sunday) remains applicable.
