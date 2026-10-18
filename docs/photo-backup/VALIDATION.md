# Exact-folder backup validation — 2026-10-17

Development used only mock credentials, temporary byte fixtures and in-process backend/Google API responses. No Google account was connected and no real photograph was uploaded.

| Check | Current observed result |
|---|---|
| Swift Foundation production backup core | 34 tests passed on Linux, Swift 6.0.3 |
| FastAPI/SQLite/Google protocol fixtures | 56 tests passed, Python 3.12 |
| AI/framing/Gemini portable regressions | 393 tests passed |
| Sony portable regressions | 75 tests passed |
| Gemini private-build policy fixtures | 30 tests passed |
| Exact protected camera/AI/Gemini/Sony/editor hashes | 70 unchanged |
| Project/source/configuration guards | Passed; deterministic project, 713 registered native XCTest functions |
| Owner Picker JavaScript | Syntax checked; real Google browser flow requires owner setup |
| Native simulator XCTest | **713 passed, zero failures**, Xcode 16.4, [CI run 39037161938](https://github.com/r3hal/focal-private/actions/runs/39037161938) |
| Unsigned Release iPhone archive | **ARCHIVE SUCCEEDED**, same completed native job |
| Backend Docker/Caddy configuration | Docker build and HTTPS configuration validation passed in that same CI run |
| Physical iPhone / real Google / Windows | Not performed |

New fixtures cover missing/read-only/trashed/wrong folders, OAuth without a folder grant, rate-limited access, permission loss/recovery, exact parent verification, moved files without duplication, bad final parents, deterministic naming, RAW byte preservation, database binding/legacy refusal, device isolation from owner browser tokens, origin/CSRF/session expiry, OAuth callback security and owner-only Picker configuration. The native backup tests additionally preserve a pending capture after folder permission loss and verify rate limits can recover after more than one retry burst.

All three jobs in [CI run 39037161938](https://github.com/r3hal/focal-private/actions/runs/39037161938) completed successfully for source commit **`f2e560b5d532c669c66205ab8fce753c3e4b6347`**, tree `0f447ab57fdea155b43bc50c3c0a727179c9ccd7`, on `codex/focal-exact-drive-folder`. The native log explicitly records `Executed 713 tests, with 0 failures`, `TEST SUCCEEDED` and `ARCHIVE SUCCEEDED`. The portable job independently passed 34 Swift backup tests, 56 backend fixtures, 393 AI/Gemini tests, 75 Sony tests and 30 Gemini build-policy tests. The container job built the backend and validated Caddy configuration. This final evidence update changes documentation only; production/test/project sources are identical to the CI-tested revision.

The build still emits existing CameraController Sendable warnings and a deprecated Keychain-option warning inherited from the previous backup implementation; no compiler or test errors occurred. Those camera sources were deliberately not rewritten for this task.

The inherited backup baseline passed 712 native tests and an unsigned Release iPhone archive at source `3190cc0ac34a57179d188b3e18b776c6f1b4a349` in [CI run 39034539352](https://github.com/r3hal/focal-private/actions/runs/39034539352). An earlier exact-folder run was superseded by the Settings diagnostic fix and is not the evidence used for delivery.

Background URLSession configuration, simulated offline/cellular paths and OS delegate guards do not establish actual 5G or background scheduling. The [real-device checklist](SETUP.md#8-physical-device-acceptance-checklist) remains necessary. Linux has no Xcode; native verification was performed separately in macOS CI. No deployed-backend, real-account, Windows or physical iPhone result is claimed.
