# Photo backup validation record — 2026-10-17

Development used only mock credentials, temporary byte fixtures and in-process backend/Google API fixtures. No Google account was connected and no real photograph was uploaded.

| Check | Observed result |
|---|---|
| Swift Foundation production backup core | 32 tests passed, Swift 6.0.3 on Linux |
| FastAPI/SQLite/Google protocol fixtures | 36 tests passed, Python 3.12 |
| Existing AI/framing/Gemini production portable regressions | 393 tests passed |
| Existing Sony production portable regressions | 75 tests passed |
| Existing personal Gemini build-policy fixtures | 30 tests passed |
| Project/config/source guards | Passed; 711 registered native XCTest functions, 111 app/40 test source references |
| Backup scope/consent/privacy/secret guards | Passed; 70 exact protected source hashes |
| Swift syntax parse | Passed for backup sources, persistence tests and changed app/library sources; not type-checking UIKit/SwiftUI |
| Native iOS XCTest on first published revision | Passed in [CI run 39033210894](https://github.com/r3hal/focal-private/actions/runs/39033210894), commit `81ca4a7`; final authorization-hardening revision will be rerun |
| Backend container and Caddy configuration | Passed in the same CI run |
| Xcode on development machine | Unavailable: `xcodebuild: command not found` |
| Physical iPhone/Google Drive/Windows | Not performed; owner setup and hardware acceptance required |

The dedicated branch workflow runs native simulator XCTest, unsigned iPhone archive and backend Docker build. The native simulator step passed on the first published revision. The two additional authorization regressions pass locally; native/unsigned archive validation is being rerun for the final revision. Workflow configuration alone does not establish a successful app build. Four added persistence tests require native UIKit and are not counted among the 32 portable tests.

Covered by automated fixtures: post-commit hook ordering/source guards, persistent/idempotent enrollment, offline delay, HEIC/RAW byte preservation, background-task adoption/stale rejection, restart recovery, destination/device/host isolation, authorization failure, quota/Retry-After, safe paths, corrupted queue preservation, known SHA-256 digest, staging cleanup, invitations/recovery/revocation, server offset crash recovery, corrupted media rejection, storage budgets, PKCE/state replay protection, encrypted tokens/session state, refresh expiry/revocation, Google owner binding, real Drive resumable request construction, range resumption, pre-reserved IDs, deduplication, verified completion and Google quota preservation.

These are **not** physical camera/radio/background-scheduler tests or benchmarks. Cellular capability and camera/AI/Gemini/Sony noninterference also have source guards and existing portable regressions; live performance, 5G, locked-device transfers, force-quit/reboot and AltStore Keychain persistence still require the [device checklist](SETUP.md#8-physical-device-acceptance-checklist).
