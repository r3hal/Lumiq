# Photo backup validation record — 2026-10-17

Development used only mock credentials, temporary byte fixtures and in-process backend/Google API fixtures. No Google account was connected and no real photograph was uploaded.

| Check | Observed result |
|---|---|
| Swift Foundation production backup core | 33 tests passed, Swift 6.0.3 on Linux |
| FastAPI/SQLite/Google protocol fixtures | 36 tests passed, Python 3.12 |
| Existing AI/framing/Gemini production portable regressions | 393 tests passed |
| Existing Sony production portable regressions | 75 tests passed |
| Existing personal Gemini build-policy fixtures | 30 tests passed |
| Project/config/source guards | Passed; 712 registered native XCTest functions, 111 app/40 test source references |
| Backup scope/consent/privacy/secret guards | Passed; 70 exact protected source hashes |
| Swift syntax parse | Passed for backup sources, persistence tests and changed app/library sources; not type-checking UIKit/SwiftUI |
| Native iOS XCTest | **712 passed, zero failures**, Xcode 16.4, [CI run 39034539352](https://github.com/r3hal/focal-private/actions/runs/39034539352) |
| Unsigned Release iPhone archive | **ARCHIVE SUCCEEDED** in the same native job |
| Backend container and Caddy configuration | Build and configuration validation passed in the same completed CI run |
| Xcode on development machine | Unavailable: `xcodebuild: command not found` |
| Physical iPhone/Google Drive/Windows | Not performed; owner setup and hardware acceptance required |

The complete CI run succeeded for source commit `3190cc0ac34a57179d188b3e18b776c6f1b4a349` on `codex/focal-google-drive-backup`. The native log records `Executed 712 tests, with 0 failures`, `TEST SUCCEEDED` and `ARCHIVE SUCCEEDED`. The portable and backend-container jobs also succeeded. This final report update changes documentation only; production/test/project sources remain those verified by CI. Four added persistence tests execute native UIKit and are included in the 712 native tests, not among the 33 portable tests.

The earlier complete run [39033210894](https://github.com/r3hal/focal-private/actions/runs/39033210894) also passed. Intermediate runs were superseded during authorization/offline recovery hardening; they are not used as evidence for the final source revision.

Covered by automated fixtures: post-commit hook ordering/source guards, persistent/idempotent enrollment, offline delay, HEIC/RAW byte preservation, background-task adoption/stale rejection, restart recovery, destination/device/host isolation, authorization failure and persisted whole-queue suspension, fail-closed opt-out, prolonged-outage recovery without clearing revoked grants, quota/Retry-After, safe paths, corrupted queue preservation, known SHA-256 digest, staging cleanup, invitations/recovery/revocation, server offset crash recovery, corrupted media rejection, storage budgets, PKCE/state replay protection, encrypted tokens/session state, refresh expiry/revocation, Google owner binding, real Drive resumable request construction, range resumption, pre-reserved IDs, deduplication, verified completion and Google quota preservation.

These are **not** physical camera/radio/background-scheduler tests or benchmarks. Cellular capability and camera/AI/Gemini/Sony noninterference also have source guards and existing portable regressions; live performance, 5G, locked-device transfers, force-quit/reboot and AltStore Keychain persistence still require the [device checklist](SETUP.md#8-physical-device-acceptance-checklist).
