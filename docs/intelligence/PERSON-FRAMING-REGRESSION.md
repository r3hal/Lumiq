# Selected shot stalls before camera zoom — Focal 2.7.3 / build 31

## What the new recording establishes

Inspected `ScreenRecording_10-15-2026 14-25-49_1.mp4`: 32.700 seconds, 512 × 1112, 30 fps. The Focal segment remains at the displayed 1.1×. At 10 seconds it shows a person, a selected planned-frame boundary and upward aiming. At **11 and 17 seconds**, the same planned-frame overlay appears with **“Stability check / No safe tighter composition yet.”** At 14 seconds it shows “Hold steady” at 1.1×. The reference segment subsequently tightens the view and displays about 2.2×. No reference styling, branding or interface was copied.

The recording does not contain Core Motion values, Vision confidence, the actual target zoom, capture-queue logs or device motor acknowledgements. It cannot prove a particular rotation threshold failed, that a configuration lock failed, or that an AVFoundation ramp was called. No such hardware measurements are inferred here.

## Identified failure in the existing code

The contradictory overlay/message exposes two sources of authority. `CompositionOverlay` only renders “Planned frame” when the reading has a selected director ShotPlan ID. The controller retained that shot. But `allowPlannedZoom`, `preparingZoom` and the call into `FramingPlanner.update` still depended on the **current scene-planner candidate**. When `plan` was temporarily nil, the controller set `.missingPlan` and skipped `update` even though `framing.shotPlan` remained valid. That produces the exact selected-overlay/missing-plan combination visible at 11 and 17 seconds. The selected composition could not progress to a zoom command on those frames.

The old path also required an available two-observation subject velocity and the full configured hold before entering zoom. Missing velocity could block a reliable track as if motion had been measured. Separately, after a zoom command, camera metadata captured alongside a valid frame was rejected if analysis took more than 0.3 seconds, although the guidance frame-age policy allows 0.9 seconds. These additional gates were reproduced with controlled tests; the recording alone does not establish their numeric contribution on the phone.

## Correction in the existing director/controller

- `FramingExecutionContext` is an immutable view of existing state, not a second zoom controller. Zoom permission comes from the retained `AutomaticShotPlan` and current settings/crop checks. The scene candidate remains diagnostic context and cannot veto or replace a selected tighter shot. A candidate alone cannot authorize camera execution.
- Do not call `AutomaticShotPlan.propose` again while a tighter shot is retained. Retain its tracking identity, target geometry, score and rationale. A different tracker identity cancels it; transient scene-planner absence does not. Existing subject-retention behavior also covers a short return to searching with a retained shot.
- An aligned, reliably tracked, fresh, safe shot uses a **0.2-second confirmation** before zoom. Capture-level stability is not required for this admission. The existing handheld motion limits remain: usable measurements younger than 0.45s, rotation below 0.22 rad/s, acceleration below 0.08g. Excessive or unavailable phone motion still prevents zoom.
- A missing velocity estimate is allowed only for a reliable retained track. Known excessive/nonfinite velocity, stale frames, bad tracking, disabled AI/settings, unsafe crop and manual override remain vetoes. Velocity intervals now use frame observation times rather than varying inference-completion times.
- After first alignment, an eight-second unresolved preparation ends with an explicit timeout instead of an endless hold. This never forces an unsafe zoom. A new explicit AI session is needed after timeout/manual cancellation.
- Execution uses the selected plan's protected regions, reprojected through the tracked subject's measured affine change. A fresh planner result cannot accidentally add unrelated background regions and invalidate the already selected portrait.
- Frame-paired camera metadata is checked against the frame's observation time and the existing maximum observation age. A separate **fresh live camera sample** must agree with the target for final verification. The metadata associated with a slower analyzed frame is no longer declared stale solely because inference exceeded 0.3s. Evaluation clocks are read after their sensor snapshots, avoiding negative ages for a newer legitimate sample.
- Final READY still requires the same tracked subject, target size/position/crop, actual target zoom within tolerance, a stopped motor and stricter capture stability. The configured steady-hold duration is applied here, rather than delaying zoom admission. Original framing error tolerances are retained.

The geometry/photographic target search and quality budgets are preserved. No universal 2.2× target was added. Targets still come from observed bounds, desired bounds, supported zoom scales and device/detail limits. Already-good current frames retain the separate measured no-zoom path; the trace explicitly reports `measured_current_frame_no_zoom_needed` or `verifying_existing_frame_no_zoom_needed`.

## Real AVFoundation execution and diagnostic evidence

The existing capture queue still calls `device.lockForConfiguration()` and `device.ramp(toVideoZoomFactor:withRate:)`. It still polls the actual `videoZoomFactor` and `isRampingVideoZoom`, stages ramp rate changes and stops/cancels safely. There is no SwiftUI preview scaling, automatic shutter or new controller. The motor supervision interval now accounts for the frame-age and sampling budget; no-response, unsafe/stale tracking, thermal, manual override and absolute deadline remain bounded failures.

Each developer trace includes session/shot IDs, current/previous states and durations, required conditions, actual current/frame/live/native zoom, geometric target and reason, desired/current subject dimensions and area, framing errors, confidence/identity, measured motion with units/age, alignment/tolerance/roll, frame/camera freshness, crop permission, confirmation progress, blockers and final verification. Missing values are `unknown`.

Capture-queue events distinguish **ZOOM_REQUEST**, **ZOOM_ACCEPTED** (actual successful lock and observed ramp flag), **MOTOR_MOVED** (actual native factor changed), **MOTOR_SAMPLE**, **MOTOR_AT_TARGET**, **ZOOM_COMPLETE** and pause/resume/cancel/abort. A returned API call is not recorded as proof of motor movement. Motor arrival is explicitly separate from composition verification. Cancellation events retain the shot ID, reason, manual/interruption flags and actual native value.

In the existing developer build: **three-dot menu → Camera Settings → Developer Intelligence Lab → Prepare AI framing trace → Share AI framing trace**. Reproduce the shot first. This exports a bounded in-memory text trace (latest 512 events, no images). Opening settings may add a later pause/cancel event; preceding session measurements remain. No trace is uploaded automatically.

## Executed tests and their limits

Before the correction, the portable suite ran **217 cases with six failures**, all in the new regression tests. Those six cases exposed: retained-shot/missing-candidate veto, current-frame-candidate veto, candidate-only execution authorization, capture-duration zoom admission, missing-velocity veto and inference-latency metadata rejection. Existing tests were unchanged.

After correction, **229 portable XCTest cases pass with zero failures**, including **18 new person/trace cases**. The added cases cover the six failures plus settings/crop vetoes, manual override, immutable selected identity/target, handheld versus capture stability, bounded waiting, frame pairing, state-duration reporting, unknown measurements, bounded trace storage, protected-context reprojection, fresh actual zoom agreement and a complete director-to-manual-capture replay. Existing RAW, target-rectangle, group/frame-preservation, motion/recovery, crop/readiness and capture-payload tests also pass.

[Recorded controlled replay output](PERSON-FRAMING-CONTROLLED-TRACE.txt) shows production Foundation logic producing a geometry-derived 1.1→2.2× command in its selected test fixture, rejecting premature READY, then completing after supplied increasing zoom observations, final geometry and capture hold. **These camera/sensor observations are fixtures; they are not measurements from an iPhone and do not verify a physical motor or live preview.** The native zoom conversion in that fixture yields 4.4 hardware units with a supplied multiplier of 2; no claim that 2.2× is universally optical is made.

All **122 Swift sources** parse. Structural checks pass for 91 app and 31 test files, 469 registered XCTest functions, deterministic project/resources/build scripts, frozen baselines, unchanged Sony sources and user-only shutter wiring. The attempted native build exits 127 (`xcodebuild: command not found`). The complete 469-test iOS suite, Apple API type checking/linking and device archive must be rerun in Codemagic.

## Files and preserved functionality

`CameraController.swift`: retained-plan handoff, tracking retention, short confirmation, actual telemetry verification and motor/state diagnostics. `FramingPlanner.swift`: short admission versus final hold, bounded preparation, immutable selection result and actual live-zoom check. `FramingProgress.swift`: immutable execution context. `AutomaticShotPlan.swift`: reproject retained protected regions. `GuidanceObservation.swift`: reliable-track handling of unknown velocity. `ShotReadiness.swift`, new `FramingTrace.swift`: paired camera freshness, bounded trace and export. `EvaluationLabView.swift`: developer-only trace export. New `PersonFramingRegressionTests.swift`, portable runner, project/version metadata and documentation complete the change.

Sony connectivity/protocol code, professional camera controls, Focal camera layout, real still capture/RAW, gallery and paired photo saving are preserved. The photographer still presses the shutter manually; neither discovery nor READY releases it.

## Required physical iPhone 16 Pro Max acceptance

1. Build latest `main` with Codemagic `ios-sideload`, run its full native tests, and install Focal **2.7.3/build 31** using AltStore. Set the initial zoom before enabling AI; manual zoom after enabling intentionally overrides automation.
2. Aim at the seated person, enable AI/Automatic Zoom, follow the aiming cue. A selected tighter shot must retain its ID and progress through brief alignment into a real change in preview field of view and displayed zoom.
3. Hold through the final capture-stability interval. Confirm actual framing stops at its target before READY, then press the shutter manually. Check captured framing, RAW if enabled, and paired-preview saving where available.
4. Export the framing trace. It must show the actual request/lock/ramp, increasing native factor, stopped motor, final geometry verification and state durations. If the phone does not zoom, the trace must show the concrete failing gate or device response; that evidence is necessary to diagnose any remaining hardware-specific failure.
5. Check manual pinch/lens/AI-off cancellation, subject loss, moving/low-light subjects, already-good framing (explicit no-zoom reason) and no post-completion hunting.

**Physical hardware verification is still necessary.** This workspace cannot execute the iPhone acceptance test, observe its motor or establish smoothness/recognition quality after the change.
