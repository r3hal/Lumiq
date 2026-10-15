# Sony remote-control state repair — Focal 2.10.2 / build 36

## Root causes found in the existing code

The flicker had concrete application causes, independent of any genuine Sony restrictions:

1. `controlsBusy` included `isRefreshingSettings`. The panel used it to disable every setting, AF and the shutter during background reads. Full refreshes ran every 10 seconds and were also triggered by capability/mode changes and screen appearance.
2. The monitor cleared all `remoteSettings` when any available API changed, when mode changed, and on a polling exception. A refresh exception also cleared all `methods`. An unrelated capture/live-view command changing availability could therefore erase working exposure controls.
3. `getEvent` values were treated as complete snapshots. Missing current fields/candidates replaced confirmed values with nil/empty data. Two independently updated capability sources could alternate UI state, and delta events could reset camera status.
4. Background setting reads could invoke `getEvent` separately for each field, alongside the monitor's event requests. Available-value getter failures also prevented fallback to a working current-value getter.
5. Separate refresh and monitor tasks could interleave through the serialized client. Connection generation checks did not distinguish background reads superseded by a user command. Unchanged reads were republished, including timestamp-only changes.

These explain the observed global greying and some `Not reported` states. They do **not** establish that an unadvertised setter is supported by a particular A7 III. The developer environment cannot reach the user's camera endpoint or inspect its actual responses; exact A/S restrictions still require device diagnostics. The user's report establishes that ISO already works in M mode; that working request/write/readback path is preserved.

## Targeted integration changes

The existing SonyRemoteCamera remains the connection manager. Its existing descriptor discovery, real live-view transport/decoder, capture workflow, optional autofocus, cleanup and reconnect infrastructure remain. A Foundation value-type `SonyRemoteSnapshot` replaces separate mutable exposure/capability caches; it is not a second camera service. No iPhone, AI, autozoom, subject-AF or other camera production source was modified. No newer Sony SDK, guessed endpoint, remote zoom or fake setting was added.

- One guarded monitor owns all background reads. Screen refresh coalesces into that monitor; there is no separate refresh task. Non-long-poll `getEvent(false)` runs about every 3 seconds with a 3-second HTTP timeout. A 30-second long poll on the shared serialized command client would delay ISO/shutter actions, so short polling is deliberate. If getEvent is not advertised, the same loop uses getExposureMode when advertised; it does not create a fallback loop. Full available-command/value snapshots run every 15 seconds or after an observed exposure-mode/relevant-capability change, explicit refresh or user command.
- Last confirmed current values, candidate lists and setter availability remain intact while refreshing or after transient read errors. Missing fields are merged as omissions. Explicit empty lists and explicit setter removals remain authoritative. A getter or supported range alone cannot enable a setter.
- Unknown, Loading, Available, Unsupported, Unavailable, ConnectionError and read Error are distinct. Control availability separately distinguishes Unknown, Available, TemporarilyUnavailable, Unsupported, CommandInProgress and Error. A retained value with a failed read is visibly marked **Last confirmed value** with the error; it is not presented as a newly confirmed value.
- Only the setting with a queued/in-flight write becomes pending. Other valid setting selectors remain tappable; writes queue through the same client rather than overlapping transactions. Real capture/busy-camera restrictions still apply. Requested values are never optimistically installed. Existing single-write acknowledgment plus matching readback remains mandatory.
- A user operation invalidates an in-flight background candidate. Connection generation and read revision checks reject stale responses. New exposure modes are read into a private candidate and checked again before publishing; known changes during the read discard that candidate and retain the old UI. A failed final mode probe also keeps the previous snapshot. Old-mode choices/restrictions are replaced only with the completed new-mode snapshot.
- A mode/capability omission cannot itself mark a reader unsupported. Unsupported setters require the actual supported-method list or an explicit unsupported response. Explicit setter refusal remains stable until mode/availability changes or reconnect, rather than flickering back on at the next unchanged poll.
- Snapshots compare semantic values, not observation timestamps, and are published only when changed. The existing camera instance, stable setting identifiers, NavigationLinks, picker destination and search state are retained. Polling does not dismiss the picker; unaccepted taps do not dismiss it either.
- A single event timeout/protocol error does not disconnect the camera or clear controls. Repeated hard transport failures without recent live frames can still reconnect, and the existing actual live-view stall watchdog remains. Event error backoff cannot postpone direct capability/value refresh forever.

## Actual request and parsing paths

The protocol remains the older advertised Scalar Camera Remote API over HTTP JSON-RPC version 1.0. Wi-Fi alone does not set Connected: a descriptor service must parse and `getAvailableApiList` must return a valid response. Live view still requires real decoded image frames.

| Setting | Current choices/current value | Write |
| --- | --- | --- |
| ISO | getAvailableIsoSpeedRate → getIsoSpeedRate → actual isoSpeedRate event | setIsoSpeedRate |
| Aperture | getAvailableFNumber → getFNumber → actual fNumber event | setFNumber |
| Shutter | getAvailableShutterSpeed → getShutterSpeed → actual shutterSpeed event | setShutterSpeed |
| White balance | getAvailableWhiteBalance → getWhiteBalance → actual whiteBalance event | setWhiteBalance |
| EV compensation | getAvailableExposureCompensation → getExposureCompensation → actual exposureCompensation event | setExposureCompensation |

Arrows represent fallback when needed, not mandatory repeated calls. One event response is shared by background setting reads; it is not polled once per setting. WB modes/Kelvin ranges, shutter strings, lens f-numbers and ISO choices come only from actual responses. EV indices use only the camera-reported third/half-step conversion; omitted conversion metadata retains its confirmed same-mode value. New-mode choices/conversion details are not invented. Current values can be read-only if no fresh writable choices/setter are advertised.

## Diagnostics

Remote Controls → Export connection diagnostics → Share diagnostics exports bounded structured JSON. It records:

- Successful remote API connection versus real live-view streaming; camera model, advertised camera service, scheme/port and protocol method names.
- HTTP status/size/request ID, protocol errors, result-shape parsing failures and permitted setting feedback.
- Per-setting getter source, actual read value and option count; read failures, write acknowledgment/readback confirmation.
- Control transitions with previous/new availability and read state, last confirmed exposure mode, cause, value-source method and added/removed API names.
- Mode changes, discarded stale candidates, poll start/error policy and reconnect/lifecycle events.

Host addresses, full URLs, Wi-Fi credentials/SSID, authorization/token/cookie fields and preview/photo pixels are not exported. Private address/URL/credential text is redacted in error fields too. Diagnostic export is local and shared only by the user.

## Software validation and limits

- 75 portable Sony tests pass: 45 existing protocol/capture/settings/wire tests plus 30 new snapshot, read-fallback, mode, scheduling, per-control state and redaction cases.
- 287 framing/session/subject-autofocus tests pass as preservation checks.
- All 132 Swift files parse; deterministic project/resource/YAML/scope checks pass with 97 application files, 35 test files and 580 registered native XCTest functions.
- Structural checks verify one monitor task, its duplicate-start guard, no separate refresh task or destructive exposure resets, and no global refresh busy gating. These supplement the executed Foundation tests; they do not simulate an AVCaptureSession or prove native UI behavior.
- The M/A/S tests use controlled API responses, not a physical Sony. No real ISO read/change, lens aperture/shutter adjustment, menu interaction, native FPS or reconnect timing was verified here. Local `xcodebuild` is absent (exit 127). Codemagic's full native tests/archive and physical iPhone/A7 III verification remain necessary.

## Physical acceptance: ISO first, then other controls

1. Build `ios-sideload` from main at build 36 and install only after its full native tests/archive succeed. Connect one A7 III over DIRECT Wi-Fi; open the existing Remote Controls panel.
2. In **M**, compare the real ISO displayed in Focal with the camera. Select an actual advertised ISO, wait for camera-confirmed readback and compare again on the body. Export diagnostics if it fails; do not infer success from Wi-Fi/live view alone. Keep a selector open for at least 30 seconds while polling; it should stay open and valid options remain tappable.
3. In **A**, inspect aperture's actual setter/candidates. If advertised, change one value and verify body + Focal agree. Inspect shutter as a read value; if its setter is absent it should remain consistently disabled with the camera-mode/API explanation. Do not assume the camera must offer every setter.
4. In **S**, repeat for shutter speed, and inspect the camera's actual aperture setter availability. Switch M/A/S/P while a selector is open and confirm one completed capability update replaces the old mode without empty flashes. For a genuinely unsupported setter, verify it stays disabled.
5. After ISO succeeds, test WB mode/Kelvin and EV only where setters/choices are advertised. Compare physical display and readback. Repeat with the other body's lens after disconnecting/joining that body's DIRECT Wi-Fi; ranges must be freshly reported, not inherited from the first lens.
6. Check the real live preview, manual shutter/JPEG save, AF, main camera screen after closing the panel and manual camera/lens zoom. Introduce a brief event/network delay, then a real disconnect/sleep/wake/background cycle. A transient event failure should retain confirmed controls; genuine disconnect should clear them and permit reconnect. Check diagnostics for one poll start per connection generation and the precise cause of any restriction.
7. Return to iPhone Camera and verify existing professional controls, RAW, AI framing/subject autofocus and gallery remain intact. Other camera implementations were not changed.

Modified source: Focal/Sony/SonyRemoteCamera.swift, SonyRemoteSettings.swift, new SonyRemoteSnapshot.swift, SonyRemoteControlsView.swift, SonyAPIClient.swift, SonyControlPolicy.swift (Equatable only), SonyDiagnostics.swift and SonyDiscovery.swift (diagnostic redaction only). New tests: FocalTests/SonyRemoteSnapshotTests.swift. Also updated: scripts/test_sony_portable.py, scripts/validate_structure.py, scripts/generate_project.py, generated project, README.md, VALIDATION.txt and Sony documentation.
