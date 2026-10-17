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
| Native simulator XCTest / unsigned iPhone archive | Pending this branch's CI; no new native build claimed yet |
| Backend Docker/Caddy configuration | Pending this branch's CI |
| Physical iPhone / real Google / Windows | Not performed |

New fixtures cover missing/read-only/trashed/wrong folders, OAuth without a folder grant, rate-limited access, permission loss/recovery, exact parent verification, moved files without duplication, bad final parents, deterministic naming, RAW byte preservation, database binding/legacy refusal, device isolation from owner browser tokens, origin/CSRF/session expiry, OAuth callback security and owner-only Picker configuration. The native backup tests additionally preserve a pending capture after folder permission loss and verify rate limits can recover after more than one retry burst.

The inherited backup baseline passed 712 native tests and an unsigned Release iPhone archive at source `3190cc0ac34a57179d188b3e18b776c6f1b4a349` in [CI run 39034539352](https://github.com/r3hal/focal-private/actions/runs/39034539352). That is historical evidence, not a build result for the current exact-folder changes.

Background URLSession configuration, simulated offline/cellular paths and OS delegate guards do not establish actual 5G or background scheduling. The [real-device checklist](SETUP.md#8-physical-device-acceptance-checklist) remains necessary. Linux has no Xcode; native verification is performed separately in CI.
