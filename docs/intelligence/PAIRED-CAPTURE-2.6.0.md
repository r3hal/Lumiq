# Focal 2.6.0 / build 26 — automatic framing and a user-controlled paired save

## 1. Automatic zoom

The existing Shot Director selects a subject and measured composition. Its immutable `AutomaticShotPlan` contains the subject identity, starting/desired bounds, desired position and scale, protected regions, starting/target zoom and completion geometry. After alignment, tracking confidence, crop safety and the configured steady hold pass, the existing camera queue calls AVFoundation's actual zoom ramp. There is no SwiftUI preview scaling and no second camera controller. The target comes from current zoom multiplied by the selected composition's geometric scale, limited by available camera zoom, detail limits and safe crop boundaries; it is not a fixed factor for every subject.

Tracking and real device zoom observations continue during the ramp. Unsafe geometry, stale/lost tracking, movement or manual intervention cancel it. The existing staged ramp and stopped-motor verification remain in place. A verified result does not keep restarting zoom.

## 2. Premature readiness

The earlier implementation could treat a temporary zoom gate as completed framing; restoring settings could also register a manual override and prevent the intended zoom. Build 25 corrected those paths: a centered subject alone cannot complete a shot requiring tighter framing. Production requires a plan, actual zoom within tolerance, subject bounds/position matching the plan, safe crops, fresh tracking and a stopped motor across successive observations. An already-good composition has a separate measured, stable current-frame path.

This update also clears completed-shot verification if the subject leaves the planned geometry, confidence falls or the protected crop becomes unsafe. Previously that completed state could stay latched. It does not automatically rearm or hunt after cancellation. The shutter now checks both published and authoritative analysis-queue framing phases, so it cannot start during zoom or final verification.

## 3. One shutter press

AI never releases the shutter. The former Smart Shutter polling task and control were removed; an old persisted preference cannot activate capture. With AI Guidance on, a user press requests exactly one existing `AVCapturePhotoOutput.capturePhoto` operation. Manual photo series remain available with guidance off.

At that press, the analysis queue snapshots the eligible framing session. The camera queue checks guidance/source, the actual device zoom and whether the motor has stopped before associating it. The existing processed photo/optional RAW delegate result carries the session to the existing library save. No still is taken at discovery, before zoom or automatically when stable. No library entry is created by retaining a preview alone.

## 4. Wider scene preservation

The inspected configuration uses one active camera input and the existing video/photo outputs. A final zoomed still cannot recover pixels outside its field of view. This implementation does not claim simultaneous full-resolution wide and telephoto capture, and does not introduce an unverified multi-camera session.

Immediately before a committed zoom, Focal copies the aligned, visible pre-zoom scene into one bounded in-memory JPEG. It uses the already-owned preview analysis image, the current aspect crop and front-camera mirroring. Encoding completes before that image can be reused. The preview is persisted only if the user later captures a verified matching shot. Its earlier observation time is stored separately from the shutter-request time. It may show a different moment if the subject moves.

Manual override, source changes, AI off and analysis reset clear pending association. Loss of identity/geometry cannot attach an old scene to a new shot. Brief camera motion blocks eligibility until stable again. A missing preview still permits saving the final photograph, with an unavailable notice. Already-correct framing without a zoom saves one normal photograph, not an invented wider duplicate.

## 5. Final photograph

The final image comes from the existing full-quality camera photo pipeline at the real zoom, with current supported photo dimensions, encoding and RAW settings. Existing aspect processing, review, original camera-file retention and editing remain. A paired capture's unedited final-zoom source is labeled “Source” to distinguish it from the earlier “Wide preview.” Sony protocol/live-view/capture files are unchanged.

## 6. Resolution and quality

- **Final AI frame:** the actual camera output at the achieved zoom, followed by existing selected-aspect processing. Its measured pixel dimensions are shown in the library. Resolution depends on active format, lens, crop and capture settings; neither 48 MP nor optical zoom at every factor is promised. Supported RAW retention remains separate.
- **Wide preview:** JPEG quality 0.93, at most 1600 pixels on the long edge, never upscaled. A 1200 × 1600 preview is 1.92 MP; smaller available buffers/crops produce smaller files. Exact saved dimensions and the earlier timestamp are displayed. It is explicitly a lower-resolution live-preview representation, not a second full-resolution still or a reconstruction of missing pixels.

Preview quality is not evidence of saved-still quality. Physical-device comparisons remain necessary.

## 7. Existing library association

One `SavedPhoto` entry stores the final image plus an optional wide-preview file and `FramingCaptureMetadata`: session UUID, ShotPlan ID, starting/target/captured zoom, shutter-request time, preview time and dimensions. The existing detail picker exposes the variants; the grid adds a small “Wide preview included” badge. There is no reference-app comparison screen or branding.

The existing transaction writes the files and then the manifest, rolling back new files on failure. Editing retains the pair metadata and wide file; deletion includes both. Old manifests decode without new optional fields. Default automatic Photos export includes both as separate assets (the preview gets its earlier timestamp); manual variant export/share exports the selected image. A preview never receives the final photograph's RAW attachment.

## 8. Validation and changed files

Passed locally: deterministic project generation, source references/counts, duplicate module-type scan, lexical delimiter checks, plist/XML/JSON/resources, YAML/build-shell syntax, frozen baseline hashes, unchanged Sony sources, whitespace, and a static assertion that the camera view has only the user shutter action and no automatic shutter polling.

Registered: **386 XCTest functions**, including **16 new** session/renderer/library regressions covering unverified discovery, user-only payload creation, cancel/source-switch invalidation, AI off, moving/uncertain subjects, brief motion, stale/different plans, missing previews, already-good framing, one-still policy, completed-shot invalidation, preview dimensions, persistence/reload/deletion, edit preservation, write rollback and Sony pair exclusion. Existing zoom/readiness regressions remain. These are model/storage tests, not a real camera recording.

**No native tests ran here.** The attempted Xcode simulator build exited 127 because `xcodebuild` is absent on this Linux environment. Structural checks do not Swift-type-check the code. The user's earlier run executed 357 tests with one failure; that earlier fixture was corrected separately, but no rerun evidence is available. Do not treat the current 386 registered tests as passing executions.

Files changed:

- `Focal/Camera/ShotCaptureSession.swift` (new), `CameraController.swift`, `CameraView.swift`, `PhotoRenderer.swift`
- `Focal/Composition/FramingPlanner.swift`
- `Focal/App/CameraSettings.swift`, `SettingsView.swift`
- `Focal/Library/PhotoLibrary.swift`, `PhotoDetailView.swift`, `LibraryView.swift`
- `FocalTests/ShotCaptureSessionTests.swift` (new), `PhotoFeatureTests.swift`
- Project generator/project, structural validator, version metadata, README, validation record and this report.

## 9. Required iPhone 16 Pro Max verification

Run Codemagic `ios-sideload` on this commit; native tests and device archive must succeed before installing its IPA with AltStore.

Then test the complete cat sequence: enable guidance/automatic framing, aim and hold, observe real camera zoom, wait for verified ready, confirm that nothing saves automatically, press once, and open both variants in the single library entry. Check actual dimensions/timestamps, important-region crop safety and live-preview/final-image framing. Repeat with chair/object and already-good compositions.

Verify pinch and manual-lens cancellation, AI off/on, subject movement/loss, low confidence, camera switching, interrupted ramps and no oscillation after completion. Check missing-preview fallback, capture errors/retry, RAW, review/edit, automatic Photos export, relaunch and deletion. Actual lens transitions, motion stability, preview encoding latency/memory and capture callback behavior require hardware. No physical-iPhone verification or new reference-video inspection is claimed.
