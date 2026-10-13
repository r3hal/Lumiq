# Sony wireless integration — experimental native adapter

## Evidence and scope

Sony's [A7 III guide](https://helpguide.sony.net/ilc/1720/v1/en/contents/TP0001653182.html) documents Ctrl w/ Smartphone and a DIRECT Wi-Fi connection. The [Camera Remote Command page](https://support.d-imaging.sony.co.jp/app/cameraremotecommand/en/index.html) lists models including ILCE-7M3 and ILCE-6100, but this is not proof that every model/firmware supports this iOS transport. The developer's [ScalarWebAPI bench findings](https://github.com/jongan69/expo-sony-camera/blob/main/docs/PROTOCOL_FINDINGS.md) document an A7 III endpoint/protocol; that project's iOS wireless implementation is absent. These observations informed an original Swift adapter, not a copied dependency or a claimed hardware test.

This implementation supports a **capability-advertised ScalarWebAPI service**. USB/PTP and PTP/IP need a separate adapter if the camera does not advertise ScalarWebAPI. A7 III and A6100 compatibility remain pending physical tests. No model name alone enables controls.

## User connection

1. On the Sony, enable **Ctrl w/ Smartphone** and open its Connection screen to display the DIRECT network/password. Keep the camera awake, with a memory card and still-photo mode selected.
2. On the iPhone, join that camera's **DIRECT Wi-Fi** in Settings. The network may have no internet; stay connected to it.
3. In Focal, open **… → Camera Source → Sony**. In Focal 2.0, use **Find camera on Wi-Fi** to validate real descriptors on the current subnet, select one, and connect. Manual private IPv4 entry remains available; there is no assumed default camera IP. Allow iOS **Local Network** access. If denied, enable it in iPhone Settings for Focal.
4. Focal probes `/DmsRmtDesc.xml` on ports 64321 and 61000. It uses the descriptor's actual camera action URL, not a guessed control endpoint. It queries `getAvailableApiList`; optional `startRecMode` is followed by capability re-query. `startLiveview` or an advertised live URL must supply the stream.
5. A validated decoded camera JPEG is required before the state becomes streaming. No phone preview appears in Sony mode. Failure provides a reconnect screen; the three-dot source picker or Return to iPhone restores the native camera.

## Actual behavior

Sony's binary live-view common/payload headers are decoded incrementally; metadata packets and padding are handled. Buffers/frame dimensions are bounded. Stream display is limited to ten delivered frames per second; Vision admission control and its five-Hz analysis drop backlog. Analysis uses the same detector/tracker/projection/coaching logic as iPhone mode. The preview shows actual received pixels; a low-resolution camera stream cannot be turned into a sensor-resolution preview. Settings shows the last received model/resolution.

`getEvent(false)` supplies real exposure mode, ISO, shutter and f-number when present. Unknown fields are dashes. A nonzero Sony exposure-compensation step is not labelled EV without a verified conversion. These exposure values are read-only. Touch focus is sent only if `setTouchAFPosition` is advertised; absent controls are not shown as supported. Phone gyro data is never treated as Sony camera motion; Sony readiness means stable image alignment, not measured physical Sony steadiness.

Shutter is enabled only with live view plus advertised `actTakePicture`. It requests a real camera capture and transfers the returned JPEG URL. A failed transfer explains that the camera may have saved a shot on its card. No preview frame is substituted as a captured photo. Transfer resolution is decided by the Sony camera/protocol, not assumed full sensor resolution; RAW remains on the camera and is not offered as transferred RAW. Focal's selected JPEG aspect crop still applies. Burst and smart shutter are iPhone-only.

No Sony lens-zoom command exists. Guidance may recommend moving the camera/zooming on its lens; automatic AVFoundation zoom remains iPhone-only. The yellow footer Scan button only rearms analysis. Settings/gallery/background pause the stream; return reconnects only if the user previously requested a Sony connection. Connection generations reject late frames/captures after a source change. Disconnect/failure clears received frames and capabilities. If advertised, stopLiveview is attempted during cleanup before a new connection starts.

Only canonical private/link-local IPv4 camera addresses are accepted. Descriptor, stream and photo URLs must refer to that exact address, without credentials. Redirects are refused. XML external entities are disabled. Local HTTP declarations use iOS 17 private-range exceptions and `NSAllowsLocalNetworking`, with no global arbitrary-load exception; see [Apple ATS documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking). No multicast discovery entitlement, proprietary SDK, API key, cloud relay or paid Apple service is required by this adapter.

## Independent test matrix (all pending)

- A7 III: record firmware, remote mode, host, descriptor, available methods, actual frame dimensions and timestamp progression. Confirm a genuine live camera scene and shutter JPEG transfer, then people/pet/object boxes and each selected ratio.
- A6100: repeat independently. Do not infer compatibility from the A7 III outcome.
- Denied Local Network, wrong host, no Wi-Fi, unsupported protocol/mode, camera asleep, competing Sony app, stream disconnect, no card and failed JPEG transfer: show honest failure; no native preview or stale ready box in Sony mode.
- Unsupported touch focus/ISO/EV/RAW/zoom: no fabricated capability or metadata. Use camera controls for exposure and lens zoom.
- Switch to iPhone while connecting/capturing; leave/reopen Settings/library; background/foreground; reconnect after Wi-Fi loss. Late frames cannot overwrite iPhone analysis or save a stale capture.
- Compare the transferred JPEG to camera-card originals, documenting any Sony transfer-size restriction. Verify unmodified original bytes, selected aspect crop and gallery/Photos export.

Pure descriptor/packet/telemetry tests are included in XCTest. They have not run in this Linux environment. They do not replace network, firmware, iOS permission or physical camera validation.
