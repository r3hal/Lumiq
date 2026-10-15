# Focal 2.6.1 / build 27 — stuck framing regression

## Recording evidence and limits

Inspected both newly supplied MP4s with timestamp-sampled frames:

- October 13 reference, duration **4.900 s**: wide classroom at 0.5×, chair selected around 2.5 s, left/up aiming instruction, “Centered — framing up…” around 3 s, then the displayed zoom changes to about 2.5× around 4 s and the selected chair remains the target. This is a behavioral reference; no reference-app UI, code or model is imported.
- October 15 Focal recording, duration **8.267 s**: cat detection remains visible; approximately 0 s subject acquired, 2 s paused, 4 s hold while settling, 6 s paused. Displayed zoom remains 1.8× in sampled frames. This confirms a visible stall, but the recording contains no gyro, tracking-confidence, ShotPlan, manual-override or AVFoundation telemetry. It cannot identify which specific device gate fired.

The test rectangles and gyro values below are controlled fixtures, not fabricated measurements from these videos. No patched app was run on a physical iPhone here.

## 1. Confirmed causes in the actual code

Two defects were reproduced by executing the previous release's production Swift model:

1. **Hold starvation from subject motion.** The ramp needed a consecutive dwell, but a 0.035 normalized box-center change between frames or 0.04 aggregate anchor drift reset it. A cat alternating only ±0.02 horizontally remains inside the measured aiming envelope yet resets every hold. Subject motion was effectively counted again as camera instability even when Core Motion reported a steady phone. The regression fails on the prior source.
2. **One-sample loss became permanent cancellation.** Missing bounds, one low-confidence sample, stale data or one unstable motion sample reset the active director and called `cancelZoomRamp`. Because a ramp was active, cancellation set both camera `automaticZoomBlocked` and analysis `automaticShotArmed` to their disarmed values. There was no bounded recovery of that shot. The one-missing-frame regression returns `cancel` on the prior source.

Additional inspected hazards were corrected:

- The video callback queued a fresh zoom read but immediately used the previous cached sample. It now samples on the owning camera queue before dispatching this frame's analysis.
- JPEG retention ran before a freshness-gated zoom command. The real motor command is now queued first; the owned buffer still supplies the earlier wide preview, and encoding does not hold up dispatch of the zoom command.
- The selected subject could undergo expensive semantic discovery during aiming even when retention was requested. Healthy retained tracking now returns before that discovery stage, preserving identity and reducing avoidable inference latency.
- The pre-zoom aiming target depended on temporary crop permission. It now remains the same frozen aiming target while transient gates are checked.
- A rejected command could return without resolving a pending director state. Rejection now records a reason and closes only the matching shot ID, without touching a newer shot.

A stationary, aligned synthetic cat at 1.8× **already passed** on the previous source. Therefore this is not evidence of a universal inability to command zoom at 1.8× or a proven zoom-unit error. Those unit conversions were already implemented correctly. The videos alone cannot establish whether motion, override, exposure/crop safety, tracking, device control or another gate was decisive in that individual session. The new logs distinguish them.

## 2. Why “Automatic framing paused” appeared

The guidance used a generic message when framing was `.off` without verified completion. Multiple cancellations all led there, including the temporary problems above. They also shared the disarmed path used for genuine manual override. This hid the distinction between a one-frame problem and the photographer taking control.

The existing director now retains an explicit block/stop reason. Guidance can explain motion, missing motion measurements, tracking recovery, stale frames, quality/crop limits, manual control, configuration failure, unresponsive zoom, thermal limits or timeout. Manual override still wins and requires an explicit new AI session; a transient tracking pause does not masquerade as manual override.

## 3. Progression, stability and shot locking

The existing `FramingPlanner` owns progression; no duplicate camera or zoom controller was added.

- Discover/select a measured composition and retain its stable ID.
- Keep the chosen subject through aiming, hold and ramp; healthy tracking does not rescan unrelated background objects.
- Aim using the real pre-zoom target and preview projection. Left/right/up/down signs are tested. Mirrored front-camera instructions now account for horizontal mirroring while retaining the same image-space target.
- Use Core Motion independently from subject-box motion. Framing accepts fresh samples below **0.22 rad/s rotation and 0.08 g user acceleration**, compared with the earlier stricter 0.12/0.04 gate. These are explicit handheld framing policy values, pending physical-device tuning; they are not measurements extracted from the clip or a promise of blur-free capture.
- Permit modest tracked relative motion (up to 0.35 normalized units/s), while requiring confidence, safe geometry and alignment. A fast subject or moving phone still cannot start the ramp.
- Accumulate eligible hold time only while aligned and stable. Brief ineligible samples pause credit; long gaps clear it. Large position changes still require re-aiming. A blocked hold reports the actual reason within four seconds rather than indefinitely displaying an unexplained hold. Quality, missing-plan, stale-data and unavailable-sensor reasons can appear immediately. No timeout forces an unsafe zoom.

An active ramp pauses the real motor on a temporary tracking, motion, freshness or quality problem. It retains the same ShotPlan and zoom target. Recovery requires successive good observations over at least 0.2 s, then resumes toward that target. Recovery is bounded to **two interruptions and 1.25 s cumulative recovery time**; identity changes and unsafe crops cancel immediately. The existing 7 s overall ramp/verification deadline and 1.1 s analysis watchdog remain. These limits prevent endless stop/start recovery or a fake READY.

## 4. Actual automatic zoom and strict completion

The aligned safe plan supplies `targetZoom = startingZoom × selected geometric scale`. Existing device/detail limits, optical stops and protected subject/context regions constrain it. There is no fixed 2.5× target. The controlled 1.8× regression chooses a valid 2× relative crop, so its calculated request is 3.6×; this does not promise that crop is safe for every cat or lens.

The existing camera queue converts displayed zoom into actual device units using the virtual-camera multiplier, locks the active `AVCaptureDevice`, and calls `ramp(toVideoZoomFactor:withRate:)`. The existing staged rate profile remains. Temporary pause uses `cancelVideoZoomRamp` while retaining the target; recovery issues a ramp only after validated tracking returns. Pinch, manual lens/mode changes, AI off and camera changes retain their cancellation priority.

The real device factor is polled every 50 ms. A new watchdog detects a command that produces no meaningful zoom movement within 0.85 s and reports `zoomNotMoving`. A command being accepted is never treated as proof it moved. Movement followed by a stall is bounded by the overall deadline.

READY still requires actual zoom within 2%, a stopped ramp, matched subject scale/position, confidence, freshness and safe protected regions over successive observations. A composition mismatch resets completion dwell. An already-good frame uses the existing measured-current-frame path; prior wait reasons are cleared when that frame is verified. No automatic photograph is taken.

## 5. Diagnostics

Development/evaluation builds log:

- Stable plan/shot ID, subject, current/desired bounds and numeric alignment error.
- Current displayed zoom, target, native `videoZoomFactor`, multiplier and motor state.
- Rotation magnitude, acceleration magnitude, sensor age, relative subject speed, tracking confidence and frame age.
- Hold progress, wait duration, recovery state, automatic permission and detail/device limits.
- State/reason changes plus numeric snapshots at least once per second during a persistent state.
- `ZOOM_REQUEST`, `ZOOM_ACCEPTED`, `ZOOM_PAUSE`, `ZOOM_RESUME`, `ZOOM_COMPLETE`, `ZOOM_REJECTED`, `ZOOM_ABORT` and cancellation reasons.

Logs are local development console output under `DEBUG || FOCAL_EVALUATION`. Normal Release has no per-frame production logging. Codemagic's existing `ios-evaluation` workflow enables evaluation diagnostics; console access still requires device tooling. The recordings are not represented as telemetry logs.

## 6. Files changed

- `Focal/Camera/CameraController.swift`: queue sampling, progression/recovery integration, real motor pause/resume/watchdog, pre-encoding command dispatch and diagnostics.
- `Focal/Camera/SubjectTracker.swift`: early healthy locked-subject return.
- `Focal/Composition/FramingPlanner.swift`: separate hold/recovery/stop reasons and strict verification dwell.
- `Focal/Composition/FramingProgress.swift` (new): reason definitions, measured motion gate and real-progress watchdog policy.
- `AutomaticGuidance.swift`, `GuidanceObservation.swift`, `SceneCompositionPlanner.swift`: reason-based feedback, modest subject motion and stable plan IDs.
- `CompositionEngine.swift`, `SubjectIdentity.swift`: mirrored physical pan direction.
- `FocalTests/FramingVideoRegressionTests.swift`, `FramingProgressionTests.swift` (new), `AutomaticShotFramingTests.swift` (temporary-loss expectations updated; hard cancellation tests retained).
- `scripts/test_framing_portable.py` (new), project/generator, structural validator, version metadata and documentation.

Focal's layout, professional controls, Sony protocol/connectivity files and user-only paired capture/storage pipeline are preserved. The optional wide preview remains an earlier lower-resolution representation, as documented for build 26.

## 7. Executed validation

- **Before:** replayed the three video-sequence regression cases against the prior source tree: one passed, two failed (small-movement hold starvation and one-frame cancellation).
- **After:** **60 XCTest cases passed, zero failures**, using Swift 6.0.3 on Linux. Includes 23 new tests plus the existing portable framing/geometry tests. The portable runner copies production algorithm files unchanged and supporting Swift data declarations verbatim; it does not substitute a fake camera or call Apple camera APIs. Tests cover cat at 1.8×, alignment, modest movement, hold interruptions/long gaps, recovery/resume budget, unsafe crop/identity loss, failed command diagnostics, actual-factor unit conversion, stopped-motor verification, continuous completion dwell, manual/AI cancellation, already-good frames, shutter-payload matching and projected/mirrored directions.
- **Syntax:** Swift frontend parsed all **115 app/test Swift files** successfully. This is real grammar parsing, but not iOS type checking or linking.
- **Structure:** deterministic project, 87 app / 28 test sources, **409 total registered XCTest functions**, resources/configuration, frozen baselines, unchanged Sony sources, user-only shutter wiring and whitespace pass.
- **Xcode attempt:** simulator build cannot run: `xcodebuild: command not found` (exit 127). The entire 409-case iOS suite and device archive remain pending in Codemagic.

Reproduce the portable subset with an installed Swift toolchain:

```sh
python3 scripts/test_framing_portable.py
# After this release is committed, reproduce the previous two failures:
python3 scripts/test_framing_portable.py --baseline HEAD~1
```

A passing model test does not establish real AVFoundation zoom, lens transitions, camera latency or captured-photo framing on an iPhone.

## 8. iPhone 16 Pro Max acceptance

Build `main` with Codemagic `ios-sideload`, install the successful IPA through AltStore, and confirm **2.6.1/build 27**. Start a fresh AI session by toggling guidance off/on after any manual zoom; enable Automatic Zoom and Subject Tracking.

Repeat the cat-under-table scenario from a wide view: detect and retain the cat, follow the aiming cue, hold, observe the actual zoom number and preview enlarge, then see final verification/Shot ready. A genuine quality or crop limitation must state its reason. If the current composition is already good, readiness must be measured without an unnecessary zoom.

Repeat with an isolated chair. Introduce a small cat movement, briefly cover the subject, pan more strongly, pinch, change lenses, disable AI and switch cameras. Verify bounded recovery only for the same safe subject, immediate manual priority, no rearming against manual choice and no oscillation. Verify the 1.8× start with a device-supported safe tighter target, rather than assuming the reference's fixed 2.5×.

Finally press the shutter once after framing: no earlier automatic capture, final still matches preview/zoom, optional earlier wide preview is labeled and grouped, RAW/review/export still work. Actual motor progress, thresholds, tracking through lens changes and both saved results remain unverified on physical hardware here.
