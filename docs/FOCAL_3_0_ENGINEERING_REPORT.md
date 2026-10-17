# Focal 3.0 integration engineering report

Date: 2026-10-17  
Integration branch: `codex/focal-3-integration`  
Starting point: `codex/focal-exact-drive-folder` at `61753417d76de4571d741412b7f161d72feead5d`

## What was inspected

The integration branch starts from the verified exact-folder backup branch. Its history already includes the compatible Phase 1 camera reliability, experimental Gemini Cloud Composition Scan, and owner-controlled Google Drive backup work. Those branches were not merged again. The divergent `ai/framed-evidence-reliability-20261016` branch had one unique AI reliability commit; its subject inference admission, composition plan retention, outdoor evidence continuity, and camera lifecycle changes were reviewed and selectively incorporated. No Sony or Fujifilm implementation was taken from another branch.

## Changes on this branch

AI guidance now carries a selected composition identity through routine candidate updates, preserves an adequately supported current frame rather than chasing every tighter candidate, and resets selection only after identity, evidence, timing, or scene changes justify replanning. Outdoor guidance uses consistent alignment thresholds and clears dwell when its evidence has a gap or a scene cut. The framing planner avoids restarting work when a stable plan ID is unchanged. Optional Vision inference observes a frame freshness deadline and avoids doing further expensive work on stale frames. Manual zoom pauses optional inference, and camera interruptions invalidate pending inference, framing, autofocus, and READY work; a resumed session replans only when the user had AI guidance enabled. Lens changes preserve the active user session while recalculating framing. The selected AI subject remains the autofocus target; autofocus stays independent of AI zoom.

The new tests exercise stable composition IDs, measured scene changes, retention of a verified current composition, manual zoom, inference freshness, plan diagnostics, READY continuity, and autofocus independence. They use deterministic fixtures; they do not substitute for camera hardware testing.

Cloud Composition gained a mockable authenticated proxy client seam. It accepts an HTTPS endpoint and a short-lived account credential from an injected provider, checks the endpoint and credential, bounds duplicate request IDs, validates the response envelope and rejects Sony live view. It contains no owner Google credential, shared Gemini key, or default proxy account. No production proxy, enrolled-device identity provider, or live Gemini call is configured. Existing first-use disclosure remains required before image transmission. The current Gemini provider integration remains experimental and independent of Drive backup.

The public IPA path validates an unsigned app archive before packaging it for public Codemagic artifacts. The scanner rejects configured key/token patterns and embedded development credential files, checks the app bundle and executable, and writes the artifact only after validation. A regular unsigned Debug IPA workflow is added without the private cloud secret group. The personal cloud workflow remains a separate manual path and must not publish artifacts. These checks reduce accidental credential release; they cannot prove that an unknown secret format is absent from all possible binary encodings.

The exact-folder backup implementation remains the previously audited owner-controlled backend flow for folder `1z7BpcVwsZAJ5ruPRHKbJ6VbnsQbOhrkU`. This integration did not upload a photo, deploy a backend, grant a test device access, or change Sony photo behavior. Friend-device upload still requires clear consent and explicit device enrollment at the backend. Sony photos remain excluded unless Focal has obtained the original file bytes.

## Validation evidence

Recorded in the active workspace before this report was written:

| Check | Result |
|---|---|
| Portable framing/composition Swift package run | 416 tests passed, 0 failures (`/tmp/focal3-framing-third.log`) |
| Public IPA packaging policy tests | 12 tests passed |
| `scripts/validate_structure.py` | Passed; project generation is deterministic, 112 app and 42 test Swift references, XML/plist/assets/YAML/shell, whitespace and safety guards pass |
| `scripts/validate_backup.py` | Passed; 70 protected source hashes, 8 reviewed changes, post-commit enrollment and backup security guards pass |
| `scripts/validate_focal3.py` | Passed; 32 preserved files and integration boundaries pass |
| Sony portable test script | Not rerun successfully in this workspace: `swift` is not installed or on PATH |
| Native Xcode simulator tests and unsigned iPhone archives for this branch | Not run in this workspace; Xcode is unavailable |
| Physical iPhone / Sony / Drive / Gemini service checks | Not tested |

The passing portable framing result was produced by the same portable script before its Swift toolchain disappeared from the current execution environment. It is recorded as that test run, not as a native Xcode build. The GitHub Actions workflow on this branch is intended to provide macOS-native test and archive evidence after publishing the branch; no result is claimed until that workflow actually completes.

## Remaining boundaries

The original real-device READY/framing loop has not been reproduced on the iPhone during this session, so its precise hardware cause is still unproven. AI transition diagnostics now carry stable plan identity and transition reasons, but exposure, autofocus, ramp completion, thermal behavior, lens hand-off, and preview quality need a physical-device pass. The proxy client is an integration seam only; production use requires a deployed HTTPS service with account authentication, enrollment/revocation, narrow Google Drive folder write permission, abuse controls, and secret rotation. No tester photos should be sent until those pieces and consent copy are reviewed. Google Drive automatic retry/background behavior also needs device verification, especially under iOS force-quit and large RAW transfers.

The integration branch is not merged into `main`. Publishing it creates a reviewable branch and triggers CI; it does not release an IPA to users or deploy the cloud proxy.
