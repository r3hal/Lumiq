# Focal 1.11 / build 14 — supplied 12-state design

The supplied image was compared against the current SwiftUI source. This workspace cannot run the app or capture iOS screenshots; visual matching has not been verified in a simulator or on an iPhone. The existing app was updated rather than rebuilt.

## Audit and implementation

Already present: native AVFoundation preview/capture, RAW/ProRAW where advertised, full-size originals, lens/pinch zoom with immediate ramp cancellation, focus and continuous white balance, real exposure telemetry and adjustable phone EV, Vision people/pet/object detection and tracking, relevance/hold/zoom logic, local gallery/editor, permission/lifecycle handling, Sony discovery/advertised API controls, validated JPEG streaming, actual image analysis, capture recovery and reconnect handling.

UI gaps: the options were a system popup rather than the reference's grouped sheet; source selection was a picker; Sony setup was embedded in the preview; the AI footer was plain text; lens buttons were separate dark circles; the target cross persisted during AI; pet/tracking/smart-selection preferences had no dedicated controls. The previous bottom-right control changed to a restart action after framing, conflicting with the new request to always toggle guidance.

The camera now uses exact #FFD32A yellow and #4CD964 green, black backgrounds, thin white controls, an immersive fitted viewfinder with rounded corners, a compact lens pill with yellow selected stop, the white shutter, yellow AI toggle, measured guidance cards and subtle press/transition feedback. Native safe areas are retained; no device frame, status bar or example photographs are rendered as UI. Layout responds to the available window size, including the intended iPhone 16 Pro Max, rather than assuming a fixed screenshot resolution. The standard phone preview fills the available height with a center crop, and the shared projection is updated to that actual viewport ratio. Captures retain the selected photo aspect and full originals; a standard capture can include more side content than this immersive preview. Other photo-aspect previews retain their selected shape. Sony full-camera-frame mode continues to preserve the actual received image aspect; it is not stretched to match the marketing image.

| Reference state | Functional implementation |
| --- | --- |
| 1. iPhone Camera — AI Off | CameraView, normal native autofocus; no automatic boxes/card/zoom. The optional user-enabled grid/level remain off by default. |
| 2. Subject Detected | Confirmed service bounds/confidence, top subject/pet badge, thin yellow box or portrait corner brackets, detected card. |
| 3. Framing Guidance | Actual alignment instruction in the green card; measured direction arrow. The permanent target cross/ring was removed. |
| 4. Hold Steady | Actual settling state, configured hold duration and progress measured by FramingPlanner; movement resets progress. |
| 5. Automatic Zoom | Real device ramp state and adjusting-framing card; pinch still cancels through the existing native gesture/controller path. |
| 6. Great Framing | Requires valid subject bounds/confidence, ready reading and ready message after the hold/ramp. Recovery never fabricates readiness. |
| 7. Three-Dot Options | Grouped native sheet with source, aspect, phone RAW/flash, camera/AI settings and help; existing restart, flip, composition, reference and explore actions remain available. |
| 8. Camera Source | Separate source cards with actual selected state; iPhone remains the default at launch. Selecting a source does not force AI on. |
| 9. Sony Connection | Separate navigated Wi-Fi setup with real private address input, connect/cancel, permissions instructions and full guide. |
| 10. Sony Connected | Appears only after a decoded real frame; shows reported model, resolution, frame count and live-link status, Open Camera and Disconnect. |
| 11. AI Photography | Persistent Guidance, Automatic Zoom, Hold Duration, Pet Detection, Subject Tracking and Smart Subject Selection. |
| 12. Sony Live View | Existing native Sony image surface, actual shared AI observations, real supported capture/touch-focus and received exposure values. Phone RAW/flash controls are omitted. |

CameraGuideState/CameraGuidanceCard present states 1–6 on the same camera view; no duplicate camera services or timed demonstration scenes were created. Short tracker misses have a recovery card with no stale box. The hold bar interpolates measured values visually; it does not run its own completion timer. Existing exposure controls remain expandable. A small Sony telemetry strip displays only actual reported fields; aperture, ISO/shutter and Sony EV are read only. Missing fields are not populated with mock numbers.

## Behavior and settings

The bottom-right button always toggles AI on/off, including after framing. Find another subject is in the options sheet. Automatic selection remains confidence/spatial/temporal gated; no suitable subject is an expected result. Turning Smart Subject Selection off requires a tap to choose a detected region, while ordinary focus stays active. Pet Detection actually gates the animal request. Tracking off removes persistent Vision object tracking and uses fresh detections; automatic zoom requires tracking at the controller gate and in the UI. Preferences default to preserving the existing analysis features and persist in UserDefaults.

The duration selector supports 1/2/3 seconds. Existing custom durations such as 0.9 seconds are retained and shown rather than silently replaced; the camera settings slider also retains fine adjustment up to 3 seconds. Opening options suspends AI/automatic zoom while leaving the capture/stream service available. Hidden smart shutter is gated. Closing the menu respects prior manual zoom cancellation and does not repeatedly zoom an already framed shot. Source changes and background/foreground use the existing camera/transport lifecycle.

The Sony transport, discovery, JPEG parser, capability negotiation, shutter recovery and reconnect work were reused. The dashboard intentionally does not imitate the image's 78% battery, 1,248 storage or Good signal strength: those values are not provided by the implemented telemetry path. The setup hero is a native camera symbol, not a fake product photo/live feed. Sony lens zoom and exposure adjustment remain on-camera unless implemented advertised controls support them. A7 III is the initial target; A6100 remains planned and separately unverified. Phone-only editing/review restrictions remain in place.

## Verification

13 new XCTest functions cover measured UI states, off overriding stale state, no readiness without confidence/bounds, recovery, actual 3-second hold/progress reset, manual acquisition with smart selection off, tracking/zoom gating, service feature configuration preference persistence and real viewport geometry across Pro Max, smaller windows and Sony. Total: 176 native test functions.

Structural checks passed: all 49 app and 15 test source files registered, lexical delimiter balance, deterministic generator, assets/fonts, plist/shared scheme parsing, cloud YAML/shell checks and whitespace. These are not Swift grammar, type-check, rendering or performance tests.

Both the requested Xcode simulator build and test were attempted. Both returned exit 127, xcodebuild: command not found. This Linux workspace has no Swift compiler, Xcode, Apple SDK, simulator or physical camera. Codemagic ios-sideload still compiles and runs the native test target before archiving the IPA; no test bypass was added.

After building latest main and installing over the AltStore app, verify all twelve states on iPhone 16 Pro Max: safe areas/Dynamic Island/home indicator, narrow windows and larger text, press/transition behavior, controls and sheet navigation, palette/spacing against the reference, permission denial, on/off during detection and zoom, pinch cancellation across menu dismissal, duration choices, all feature switches, RAW/capture/editor/gallery and interruptions. On A7 III verify actual connection/disconnect/reconnect, setup returning from Settings/background, dashboard only after real frames, real exposure availability, supported shutter/focus, and common AI observations. Measure cadence/latency/heat with tracking on and off. Pixel matching, recognition accuracy and hardware compatibility remain pending.
