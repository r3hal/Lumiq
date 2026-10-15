# Integrated subject autofocus — Focal 2.9.0 (33)

The interrupted work was recovered from the working tree: four modified camera
files and the untracked `SubjectAutofocus.swift` were present. They were not yet
committed or published. Those changes were preserved and completed, including
manual-focus handoff, shutdown/disable handling, capture cleanup, project
registration and tests. No duplicate tracking controller or Tracking AF toggle
was added. Sony connectivity and Sony source files are unchanged.

## Implemented behavior

- The existing composition tracker supplies the autofocus identity and bounds.
  A retained ShotPlan's tracking reference has priority over a transient tracker
  challenger. Before a plan is finalized, only the existing selector's tracked
  subject can supply a focus target. No independent AF subject selection occurs.
- A fresh, confidently tracked region activates subject autofocus automatically.
  It continues through aiming, automatic zoom, final verification, READY and
  ordinary framing recovery. Neither zoom-armed state nor capture stability is
  an AF gate. The old 0.6s focus dwell and 3s interval no longer apply.
- People/faces use an unambiguous, actually observed face where available. Cats
  and dogs can use the existing animal-pose head evidence. The existing tracker
  performs bounded, targeted anatomy refreshes at most once per 0.9s, without
  restarting scene selection or creating a second `VNTrackObjectRequest`.
  Extra head inference is skipped during a ramp, rapid movement or thermal
  pressure. Cached head geometry follows the tracked body for up to 1.5s, then
  falls back to the body. Other selected objects and animals need no face.
  There is no claim of eye detection or guaranteed eye-level hardware focus.
- Focus points are smoothed and constrained inside the current subject/head.
  Changed points are proposed at most five times per second. Stationary targets
  receive a mode audit at most once per second; the device adapter skips
  unchanged continuous-AF/point settings before locking configuration.
- Coordinates pass from Vision through the existing aspect-fill/mirror
  projection into the actual `AVCaptureVideoPreviewLayer` conversion, read on
  main. The previous hardcoded portrait-to-sensor swap is removed. Observed zoom
  changes reproject the point before conversion; stale conversions or material
  zoom changes before execution are rejected. Camera changes invalidate queued
  work rather than applying old coordinates to a new input.
- On supported hardware the existing capture queue sets the device point of
  interest and `.continuousAutoFocus`. It does not write lens position, wait for
  `isAdjustingFocus` to become false, alter exposure/white balance, or restart
  the capture session. Continuous AF handles distance changes even when the
  subject's center does not move. Unsupported/fixed-focus cameras retain normal
  behavior.
- A short loss retains identity without sending fabricated observations. Normal
  continuous AF is restored after the loss window, including when analysis stops
  producing fresh frames. Fresh reacquisition automatically resumes. Genuine
  subject replacement uses a new identity and immediate fresh focus target.
- Manual focus invalidates pending focus requests and always takes priority.
  Releasing manual focus resets the focus policy so the next fresh target can
  resume automatically. Manual zoom keeps its existing zoom override while
  retaining subject tracking/AF where possible.
- AI/Auto Frame off, source/device changes, interface pauses and shutdown release
  tracking focus. Capture defers restoration until capture finishes. The shutter
  remains user-controlled, and existing paired saves, RAW and pro controls remain.

The AVFoundation conversion and capability checks follow Apple's
[preview coordinate conversion](https://developer.apple.com/documentation/avfoundation/avcapturevideopreviewlayer/capturedevicepointconverted(fromlayerpoint:))
and [device focus APIs](https://developer.apple.com/documentation/avfoundation/capture-device-focus).
Changing a point of interest does not prove optical sharpness or prescribe a
physical lens distance.

## Verification

- **275 portable XCTest cases pass**, including **21 new subject-autofocus
  tests**. These execute production Foundation policies and existing framing
  models with controlled inputs. They are not measurements from a real lens.
- All **125 Swift files** pass frontend syntax parsing; the deterministic Xcode
  project includes **92 app sources**, **33 test sources** and **515 registered
  native XCTest functions**. Resource, baseline, duplicate-declaration,
  whitespace and user-only-shutter structural checks pass.
- New cases cover immediate person focus, lateral movement, approach/recession
  while maintaining continuous AF, cat head and chair/object fallback, zoom
  phase continuity, occlusion/reacquisition, subject replacement, manual focus,
  disabled automation, timeout continuity, manual-zoom reprojection, head-cache
  expiry, update throttling, aspect-fill/mirroring and stale queued work.
- `xcodebuild -project Focal.xcodeproj -scheme Focal -destination
  'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` was attempted.
  It returned **127: xcodebuild unavailable** on this Linux host. No native build,
  Apple SDK type-check, simulator execution or archive succeeded here.
- Physical iPhone 16 Pro Max verification remains necessary for actual focus
  acquisition/sharpness, approach/recession, ROI/head observations, real preview
  coordinate conversion, zoom/lens transitions, hunting/performance, manual-focus
  handoff and restoration. Animal pose is optional and not run by simulator code.

Run Codemagic `ios-sideload` from latest `main`, then install the generated IPA
with AltStore. Check the version is **2.9.0**. Point at a seated person, cat or
chair with AI Guidance and Automatic Zoom on; no tap or extra toggle is needed.
Exercise movement, temporary occlusion, zoom, manual focus and AI off, then press
the shutter yourself. The existing developer trace records `AF_TARGET_SELECTED`,
`AF_POINT_APPLIED`, `AF_NORMAL` and configuration failures with real runtime
values. Those events report requested/applied hardware settings, not a guarantee
of sharpness.

## Modified files

- `Focal/Camera/CameraController.swift`: integrated focus dispatch, real-device
  capability/configuration checks, cancellation, manual priority and loss cleanup.
- `Focal/Camera/SubjectAutofocus.swift`: focus-only geometry, smoothing, throttling,
  loss policy and stale-request gate; no subject detector or camera controller.
- `Focal/Camera/SubjectTracker.swift`: reuse existing tracking with bounded head
  refinement and short-lived observed-head geometry.
- `Focal/Camera/CameraPreview.swift` and `CameraView.swift`: expose the existing
  preview layer for correct coordinate conversion; no layout/control redesign.
- `FocalTests/SubjectAutofocusTests.swift` and the portable test runner.
- Project generator/generated project, structural test count, version labels in
  Settings and evaluation metadata, README and validation evidence.
