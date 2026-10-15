# Focal 2.10.1 / build 35 — native-test follow-up

The supplied Codemagic log shows build 34 compiled and executed 548 tests, with three failed assertions across two test cases. This stopped the workflow before the unsigned IPA archive. These changes correct test compatibility without modifying any production source under Focal/, including Sony controls, camera capture, subject autofocus or AI zoom. Tests remain enabled and no assertions are skipped to bypass the native gate.

## Paired preview test

`ShotCaptureSessionTests.testMovedOrUncertainSubjectCannotPairOldScene` contained the old policy: discard the original wide preview after any uncertain/moved observation. The existing build-32 recovery implementation intentionally retains that timestamped preview for the same ShotPlan, suspends capture eligibility and requires fresh verified framing before pairing it. The newer `ContinuousFramingRecoveryTests.testPairedSavingKeepsOriginalWideAcrossRetryButRequiresFreshVerification` already asserts this retention contract. Returning to safe verified framing is not a new scene or a new selected subject.

Replaying the original test against the unchanged production session reproduced exactly two failed wide-preview assertions. This used opaque preview bytes in place of UIKit encoding; session logic and original assertion bodies were preserved.

The old test repeats its discard assertion for confidence 0.3 and 0.95. Its two stale `XCTAssertNil(...widePreview)` expectations conflict with this recovery behavior. It now checks that unsafe and stable-but-unverified observations cannot produce a capture, and that fresh verification of the same shot recovers the exact original preview bytes and timestamp. A separate new regression discards the plan, rejects a late stale verification, selects another shot and confirms old pixels cannot be resurrected.

The pure session tests now also run in the portable suite. Native image encoding, renderer and library tests retain their UIKit/CoreImage path; portable metadata/session tests use opaque bytes because no image decoder is involved in retaining them. The existing iOS tests are still included in the native target.

## Sony wire fixture

`SonyRemoteSettingsTests.testProductionWireClientAcceptsLegacyMethodTypesAndSendsVersionOne` unwrapped only `URLRequest.httpBody` after URLSession passed it into URLProtocol. Apple's networking layer can instead supply `httpBodyStream`. The fixture now captures actual body bytes once at interception from either representation. The production wire test still verifies the real serialized JSON's method/version and HTTP POST, plus actual parsing of the legacy plural `results` capability response.

A new test explicitly exercises both in-memory and streamed JSON-RPC bodies and compares their bytes. Stream errors/oversized fixture bodies fail explicitly. The production API client and its request/version/response behavior are unchanged.

The excerpt names the Sony test but omits its assertion/error line; the streamed-body assumption is the concrete platform-specific defect identified in that test. Its new coverage passes locally, but the full native rerun must confirm this accounts for the reported third failure.

## Validation

- 287 portable framing/session/autofocus tests pass, including 12 session cases now exercised on Linux.
- 45 portable Sony tests pass, including the production URLSession/JSON-RPC wire test and the forced streamed-body regression.
- All 130 Swift source files pass frontend syntax parsing. Deterministic project/resource/configuration checks pass with 550 registered native XCTest functions.
- No production application source changed; release metadata, tests, the portable runner and evidence only.
- Local Xcode remains unavailable. The user's log establishes build-34 test execution, not success for this follow-up. All 550 native tests and the IPA archive still need Codemagic execution. No physical camera test is claimed.

Run Codemagic `ios-sideload` on main at build 35. It still runs the full native suite before archiving; install only the IPA produced by a successful run.

Modified files: FocalTests/ShotCaptureSessionTests.swift, FocalTests/SonyRemoteSettingsTests.swift, scripts/test_framing_portable.py, scripts/validate_structure.py, scripts/generate_project.py, generated Focal.xcodeproj/project.pbxproj, README.md, VALIDATION.txt and the two Sony documentation files.
