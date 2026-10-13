# Focal 1.6.1 / build 9 — motion preview and Sony stream recovery

## Report and evidence

The user reports that stationary iPhone preview quality is good, but camera movement/zoom becomes blurry and laggy. A Sony A7 III connection reports Sony sent an invalid live-view JPEG and no picture. This is device feedback, not successful hardware verification of this correction.

Code inspection found that native preview rotation/mirroring was set on every SwiftUI update (including zoom/AI updates), the format permitted a 15 fps low-light interval, and Vision ran directly on the capture delegate while holding a full-resolution camera buffer. Pinch values produced a camera configuration for every update. Slow smooth AF and automatic low-light boost were enabled. These are concrete possible contributors; none was profiled on the user's device here.

The Sony error string is thrown only after a recognized Scalar packet is received and its proposed JPEG bytes fail exact first/last marker checks. The stream was then closed on that first failure. Packet wrappers/trailers or one bad frame can therefore prevent all live view. Tap focus also used one-shot autoFocus, which can retain a fixed lens distance after the initial tap. No actual Sony packet was captured in this workspace, so the exact offending bytes remain unknown. The developer's [Scalar findings](https://github.com/jongan69/expo-sony-camera/blob/main/docs/PROTOCOL_FINDINGS.md) also describe SOI/EOI extraction on A7 III bench traffic, supporting a marker-aware recovery path; that is separate evidence, not an iOS device test.

## Native preview correction

- Reconfigure AVCaptureVideoPreviewLayer only when its mirror/rotation values differ.
- Capture delivery gets its own queue and autorelease scope. Admit at most one analysis frame, at most four per second; copy to a bounded 1600-pixel RGB surface and return the native buffer immediately. Vision uses its separate 640-pixel surface. No capture CMSampleBuffer/native CVPixelBuffer is retained by the async inference closure. Busy inference drops arrivals instead of queuing old frames.
- Use utility/background processing for inference. During movement/manual zoom, defer discovery and coach classification, but continue actual chosen-subject tracking and automatic zoom-loss checks. No fake/predicted region is drawn as a fresh detection.
- Retain maximum supported photo dimensions in format ranking, prefer 60 fps only at that same photo budget where supported, and fix the selected 60/30 fps interval. Disable automatic low-light boost and slow smooth focus; native continuous AF/AE/WB remain. Automatic subject focus does not reset exposure metering or interrupt a focus already in progress. User tap focus/metering remains supported and keeps continuous native AF where available, rather than locking a one-shot lens distance as the phone moves. Automatic focus requests wait for stable motion and skip manual/automatic zoom.
- Coalesce manual zoom to the latest value at up to thirty camera updates per second. Cancellation is requested immediately on manual input; it does not wait for the coalesced zoom assignment. Stop clears pending targets.
- Settings reports the selected target and last observed video-data frame cadence, not display refresh rate or a sharpness score. It remains available after pausing to open Settings.

Native preview/captured photos are not replaced by a rendered low-resolution analysis image. Original JPEG/RAW data and maximum advertised photo-dimension requests remain. Faster preview exposure can need higher ISO in low light; available light, focus, hardware lens switching and digital cropping can still affect perceived detail. This is not a claim of guaranteed 60 fps or eliminated physical motion blur.

## Sony correction

A bounded incremental scanner finds the outer JPEG through binary prefixes and skips recognized Scalar metadata and packet padding. JPEG segment lengths skip APP/EXIF data, including embedded thumbnails. Entropy stuffing, restart markers, progressive scans and chunk splits are handled before accepting EOI. Marker-only streams are accepted too. Malformed framing resynchronizes; declared/frame/buffer limits still reject excessive data. A single malformed/rejected image is not fatal. Within a delivery batch, decoding can fall back to an earlier valid image when the newest is rejected.

ImageIO must parse valid dimensions, decode a bounded thumbnail and report a complete image before publishing it. Sony view never substitutes phone video. The watchdog still fails a stream that produces no real images, with received-byte/framing/frame/rejection diagnostics. The connection screen shows progress diagnostics while waiting, so a further failure can be distinguished from no incoming data. No credentials or camera image bytes are logged in that diagnostic. Advertised control gates, source selection, no Sony lens zoom and normal capture/transfer remain.

## Verification

12 new test functions cover wrapper/trailer recovery, marker streams, corruption and truncation, EXIF thumbnails, entropy/progressive scans, metadata/padding, a real UIKit-encoded fragmented JPEG, one-in-flight admission, rate limits, latest-target zoom coalescing and observed cadence. The full target contains 99 XCTest functions. **None executed here**: Xcode, an Apple SDK, Swift compiler/simulator and physical devices are unavailable. The native build command was attempted and returned xcodebuild: command not found. No Docker permission retry was attempted after the prior cancellation.

Passed structural checks: 45 Swift files (37 app / 8 tests) parse; all project/resource references, plists/privacy/scheme/permissions/assets/fonts, cloud workflow script syntax, deterministic generator and whitespace checks validate. These are not Swift type checking or runtime/performance verification. ios-sideload still runs all native tests before IPA packaging.

## Device retest — pending

1. Install the rebuilt IPA over Focal in AltStore. iPhone 16 Pro Max: compare a bright stationary scene and a slow pan with AI off/on, then indoor/low light. Read target/last-observed fps in Settings after each. Compare the same scene/zoom with Apple Camera.
2. Pinch slowly and quickly; try 0.5×/1×/2×/5× where available. Look for smooth delivery, no stale zoom replay, prompt manual cancellation, and native autofocus settling after a real lens switch. No shutter/reset/lifecycle/source regression. Verify photo/RAW dimensions and persisted original bytes.
3. With AI on, pan to a new subject and hold. Discovery resumes after settling; actual tracking stays correct. Lose the subject during automatic zoom and verify cancellation; guide off still stops inference.
4. A7 III: join DIRECT Wi-Fi, close a competing remote app, choose Sony and Connect. Verify advancing real frames, received dimensions and packet diagnostics. Check guide toggle/shared selection, supported capture and source recovery. Repeat across foreground/background and camera reconnect.
5. If Sony still shows no view, retain the **full new diagnostic message**, firmware, camera remote mode and address; no decodable-picture claim is made until that test succeeds. A6100 remains a separate unverified test.
