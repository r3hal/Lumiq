# Sony A7 III Wi-Fi Remote Controls — Focal 2.10.0, build 34

## Audit and protocol boundary

The existing service discovers Sony Scalar Camera Remote API descriptors at the selected private camera address (ports 64321/61000, DmsRmtDesc.xml). The existing bounded discovery searches the iPhone's actual Wi-Fi subnet, up to 64 hosts/four concurrent probes. Control URLs come from the descriptor's camera service; live-view URLs come from its advertisement or startLiveview. Same-camera private-host checks and redirect refusal remain in place.

Control requests are HTTP JSON-RPC using the documented version 1.0 wire format. This is **not** Sony's newer Camera Remote SDK. The existing app already queried getAvailableApiList/getMethodTypes/getEvent, decoded real Sony live-view JPEG streams, negotiated advertised live-view sizes, sent optional touch AF, and performed single-shot capture/transfer with half-press preparation. Exposure telemetry was read-only. No actual capability report from either of this user's bodies is available in this development environment. A7 III model ownership alone does not establish which Scalar commands its firmware advertises.

This change fixes the documented plural `results` response from getMethodTypes, preserving supported-method discovery. It adds no guessed service endpoint, authentication workaround or PTP/IP adapter. A camera exposing only an incompatible protocol cannot gain these controls through this implementation.

Primary protocol reference: [Sony-authored Camera Remote API beta v2.40, February 2017, archived PDF](https://be-bright.github.io/assets/documents/Sony_CameraRemoteAPIbeta_API-Reference_v2.40.pdf). This reference predates the A7 III and is used for command formats, **not model compatibility evidence**. [Sony A7 III Control with Smartphone help](https://helpguide.sony.net/ilc/1720/v1/en/contents/TP0001653185.html) describes setup but does not establish availability of every Scalar setting.

## Capability-driven controls

| Control | Read/current choices | Change | Availability rule |
| --- | --- | --- | --- |
| ISO | getAvailableIsoSpeedRate, getIsoSpeedRate or isoSpeedRate event | setIsoSpeedRate | Camera's advertised current ISO strings only, including its Auto spelling |
| Aperture | getAvailableFNumber, getFNumber or fNumber event | setFNumber | Actual mounted-lens and exposure-mode choices; no hardcoded f-number range |
| Shutter | getAvailableShutterSpeed, getShutterSpeed or shutterSpeed event | setShutterSpeed | Exact returned strings, preserving fractions/long exposures |
| White balance | getAvailableWhiteBalance, getWhiteBalance or whiteBalance event | setWhiteBalance(mode, temperatureEnabled, temperature) | Modes and Kelvin [maximum, minimum, step] from camera only; non-temperature mode sends false/-1 |
| Exposure compensation | getAvailableExposureCompensation, getExposureCompensation or event | setExposureCompensation(index) | Reported index range and step: 1 = thirds, 2 = halves; unknown steps remain read-only, with no invented EV |
| AF trigger | getFocusMode/getEvent where advertised | actHalfPressShutter then cancelHalfPressShutter | Requires a known release command; MF/busy rejected; focus lock claimed only when Sony reports Focused |
| Remote shutter | Existing available-list/event/capture workflow | actTakePicture, awaitTakePicture for explicitly pending capture only | User press only; never replay ambiguous shutter timeout; returned validated JPEG saved through PhotoLibrary |
| Live view | Actual descriptor/startLiveview URL and decoded frames | Existing supported size negotiation | No sample images; a valid control-only connection can remain usable without live view |

Methods supported by the camera and methods currently available in its mode are separate. A readable current value without available choices remains informational. A supported setter that disappears from the current list is disabled with a shooting-mode explanation. No remote zoom command is introduced. Change shooting mode and lens zoom on the camera itself.

## Confirmation and reliability

The panel is inside the existing Sony connection screen; the default iPhone camera and its controls are unchanged. Every write refreshes current command availability and lens/mode choices before sending. The request is sent once, requires a success acknowledgment, then polls up to five times for a matching camera readback. Until then the last observed value is retained with a separate pending indicator. A failed/ambiguous change clears the stale value and reports uncertainty; subsequent polling reads the actual value without resending the write.

The existing serialized API client is shared by settings, focus, capture and telemetry. The service prevents these user operations from overlapping and rejects stale feedback when a connection generation changes. Current values and ranges are cleared on reconnect/body switch; camera values are periodically refreshed, and available-command/mode changes invalidate old choices. Backgrounding cancels local work and closes the connection; foregrounding resumes the existing requested connection. The existing bounded 1/2/4-second reconnect policy remains; wake the camera, rejoin DIRECT Wi-Fi and use Reconnect if attempts are exhausted. A still-capture stream pause retains the original capture workflow, and ambiguous failures never cause a second shutter release.

The remote panel saves the unmodified transferred JPEG in Focal and respects the existing automatic Photos-export preference. The Sony's card/RAW policy remains controlled by the camera; this does not add remote RAW download. Shared live-view surfaces use weak references so opening the panel cannot steal pixel delivery from the main camera screen.

Export diagnostics from **Remote Controls → Export connection diagnostics → Share diagnostics**. Bounded JSON records descriptor/discovery outcome, model/endpoint, supported/current commands, method/request ID, response status/duration, setting feedback, requested/verified values, camera mode/status, failures and reconnect/lifecycle events. Preview pixels and photo transfer URLs are excluded from exported success responses. Error text is camera/network feedback; inspect before sharing externally.

## Verification status

**Implemented and verified in software:** 44 portable XCTest cases (33 new settings/wire/AF/diagnostic cases plus 11 existing capture-policy cases). Production client tests exercise JSON-RPC requests through URLSession with URLProtocol fixtures. Other tests use scripted camera feedback for delayed confirmation, stale lens ranges, current mode restrictions, read-only values, WB parameters, EV conversion, busy/refusal/timeout responses, one-write behavior, stale-session rejection, half-press release, MF override, diagnostics bounds and transfer-URL exclusion. All 275 existing portable framing/subject-AF regressions pass. All 130 Swift files pass frontend syntax parsing; project/resource/configuration validation passes with 548 registered XCTest functions.

**Implemented but requiring native/hardware verification:** SwiftUI panel rendering, native Apple SDK compilation, all 548 native XCTest functions, actual discovery/connection/setting feedback/AF/capture/live view on each A7 III, sleep/Wi-Fi/background recovery and Photos saving. Linux provides no Xcode or connected iPhone/Sony; `xcodebuild` attempt exits 127. No native build, physical command or live-view performance result is claimed.

**Unsupported/unavailable:** any control absent from a body's advertised current commands or available values; controls restricted by its shooting mode/lens; remote zoom; guaranteed eye AF; RAW download; new SDK/PTP-IP compatibility. These remain disabled or on-camera operations rather than simulated features.

## Physical acceptance: test one body at a time

1. Build Codemagic `ios-sideload`, install its IPA, use iPhone 16 Pro Max. Start with the Sigma 70mm A7 III in still-photo mode. Enable Ctrl w/ Smartphone, join its DIRECT Wi-Fi and allow Local Network access.
2. Menu → Camera Source → Sony Camera: discover or confirm address, connect and open Remote Controls. Check the actual model/status and live view. Export the initial capability diagnostics.
3. Compare every displayed setting to the camera. In modes that permit it, change ISO, f-number, shutter, WB mode/Kelvin and EV; confirm Sony's display and Focal's readback match. Switch P/A/S/M physically and verify unavailable setters disable. No aperture is assumed to be available in every mode.
4. Trigger AF in an AF mode on a clear edge; confirm real focus response. Repeat in MF and with an unsupported AF mode. Press Remote Shutter once and check one capture, actual camera card, Focal JPEG and optional Photos export. Verify main camera shutter and live view still work after dismissing the panel.
5. Sleep/wake the camera, interrupt/rejoin Wi-Fi, background/foreground the app and disconnect/reconnect without restarting Focal. During an ambiguous shutter interruption, inspect the camera card before another press. Confirm old ranges/values cannot survive a new connection.
6. Disconnect the Sigma body. Join the Sony-lens body's DIRECT network, discover its actual address and reconnect. Repeat steps 2–5; verify its own reported apertures replace the first body's choices.
7. Return to iPhone Camera and check RAW, professional controls, AI framing/subject AF, manual zoom, paired saving and gallery remain as before. No iPhone/AI implementation source changed in this release.

## Modified files

Sony integration: SonyAPIClient.swift, SonyConnectionView.swift, SonyControlPolicy.swift, SonyDiscovery.swift, SonyPreviewDelivery.swift, SonyProtocol.swift, SonyRemoteCamera.swift. New: SonyRemoteSettings.swift, SonyFocusWorkflow.swift, SonyDiagnostics.swift, SonyRemoteControlsView.swift, FocalTests/SonyRemoteSettingsTests.swift, scripts/test_sony_portable.py. Release/project/docs: scripts/generate_project.py, scripts/validate_structure.py, generated Focal.xcodeproj/project.pbxproj, README.md, VALIDATION.txt, this report.
