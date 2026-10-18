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
| Portable framing/composition Swift package run | 416 tests passed, 0 failures (workspace run) |
| CI portable Swift suites | 75 tests passed, 0 failures, including Sony protocol tests |
| Native iOS simulator XCTest suite | 736 tests passed, 0 failures (`FocalTests.xctest`) |
| Unsigned Release archive and Release IPA policy scan | Passed |
| Non-secret public Debug archive and Debug IPA policy scan | Passed |
| Private Debug packaging smoke test with mock credential | Passed; no real credential supplied |
| Public IPA packaging policy tests | 12 tests passed |
| Structural, backup integrity, and Focal 3 source guards | Passed; 112 app/42 test Swift references, 70 protected source hashes, 32 preserved files |
| Backup backend Docker build and HTTPS configuration validation | Passed |
| Physical iPhone / Sony / Drive / Gemini service checks | Not tested |

GitHub Actions run [39070275686](https://github.com/r3hal/focal-private/actions/runs/39070275686) completed successfully for commit `ebc2be16a04fd2f32aa927516038e5407fa1fd8a`. This provides native simulator and archive evidence, but not physical-device verification. The local shell environment has no Swift/Xcode toolchain; the portable test scripts ran on GitHub's configured runners.

## Remaining boundaries

The original real-device READY/framing loop has not been reproduced on the iPhone during this session, so its precise hardware cause is still unproven. AI transition diagnostics now carry stable plan identity and transition reasons, but exposure, autofocus, ramp completion, thermal behavior, lens hand-off, and preview quality need a physical-device pass. The proxy client is an integration seam only; production use requires a deployed HTTPS service with account authentication, enrollment/revocation, narrow Google Drive folder write permission, abuse controls, and secret rotation. No tester photos should be sent until those pieces and consent copy are reviewed. Google Drive automatic retry/background behavior also needs device verification, especially under iOS force-quit and large RAW transfers.

The integration branch was merged through [PR #1](https://github.com/r3hal/focal-private/pull/1) into `main` at merge commit `dfc481f6c606f77bf0c4fa2e5d46d97c4c2bd06e`. The rollback branch `backup/main-before-full-integration` preserves the original main commit `61081f524fb6e10d66bfb24d0e8c30953a4a9b4f`. All development branches were retained. The CI archives were validated and scanned; they were not published as user-downloadable GitHub artifacts. Codemagic's public Debug IPA workflow is configured in `codemagic.yaml`, but an actual Codemagic run was not available here. The merge did not release an IPA to users or deploy the cloud proxy.
