# Continuous automatic framing recovery — Focal 2.8.0 (32)

## What the supplied recordings establish

Both new recordings were inspected before editing the project, using timestamped
frames across their full duration and full-size frames at the failure points.
Videos and extracted photographs are kept outside the repository.

| Recording | Visible sequence, relative to the recording start |
| --- | --- |
| Focal `15-06-58_1.mp4`, 42.4 seconds | At 2s the card says **Manual control active** beneath **Stability check**. Around 10–22s the camera points at the seated person but remains in that manual session. Around 24s AI is restarted. At 26–30s the view visibly tightens and the zoom readout progresses to approximately **1.6×**. At 32s **Shot ready** appears. At 34s it is replaced by **Subject left the safe crop. Aim again and start a new AI shot**, still at 1.6×. |
| Reference `15-07-57_1 (2).mp4`, 10.37 seconds | Around 3–4s it searches, around 5s it gives an aiming instruction, and around 6–8s it tightens to approximately **2.2×** and continues with capture advice. |

This is evidence of a progression/recovery problem, not proof that Focal never
zooms. The video contains no Core Motion, Vision confidence, configuration-lock
or AVFoundation motor trace. It cannot establish which sensor threshold failed
at a particular instant, why manual control was initially latched, or the
reference app's internal algorithm. Its interface and proprietary implementation
were not copied. There is no universal 2.2× target in this fix.

## Responsible code paths

1. Phone framing used rotation **<0.22 rad/s** and acceleration **<0.08g** with
   measurements younger than 0.45s. These conditions gated both pre-zoom admission
   and verification during the ramp. A minimum 0.2s admission dwell was separate
   from, but still presented as, a stability stage.
2. Verification could pause on motion/tracking/telemetry. The old recovery budget
   was only **1.25 seconds total**, with at most two recoveries. Expiry canceled
   the shot. The motor also had a **7-second** watchdog and a **1.5-second** fresh
   verification watchdog. Aligned preparation had an **8-second** timeout.
3. `cancelZoomRamp` treated an ordinary interrupted ramp like a manual override:
   it set `automaticZoomBlocked = true` and `automaticShotArmed = false`.
   `abortAutomaticZoom` reinforced those latches and discarded the plan.
4. Successful completion also disarmed the AI session. When
   `revalidateCompletedShot` later rejected the composition, it called terminal
   `stop(.unsafeCrop)`. This matches the visible READY → restart-instruction
   sequence; the recording does not reveal the precise geometric measurement.
5. Every `.steady` message used the same **Stability check** card title, including
   manual override and unsafe-crop messages. This obscured the actual blocker.

## Updated execution and recovery

The existing phone `FramingPlanner` now opts into continuous recovery. There is
one director, one capture queue, and the existing AVFoundation ramp controller.
The legacy hold contract remains available to layout-only callers and its
existing tests; the production phone explicitly uses continuous mode.

- A valid selected shot, matching tracker identity, confidence >=0.65, fresh
  observation, safe crop, supported quality range and correct aim admit framing
  immediately. There is **no pre-zoom stability dwell or level/roll gate**.
- A fresh gross-motion filter remains: rotation <0.9 rad/s, acceleration <0.35g,
  measurement age <0.45s. Known excessive relative subject speed still blocks
  admission. These are engineering limits to validate on hardware, not sensor
  values inferred from the recordings. Strict capture stability and the user's
  configured hold duration apply only to final READY verification.
- Normal execution is DISCOVERING → SHOT_SELECTED → AIMING → AUTO_ZOOMING →
  VERIFYING_FRAMING → READY. A shot already aligned need not spend a display
  frame in AIMING. Recoveries use **REACQUIRING**, **RECOVERING_ZOOM**, and
  **REDISCOVERING**, each with a timed exit.
- Ordinary interruption stops the motor, invalidates the old motor generation,
  reads actual zoom, and invalidates capture eligibility without setting a
  manual override. A valid shot retains its ID, subject, desired bounds and
  protected anatomy/context. Watchdog expiry now requests recovery.
- Three retries use **0.4s, 0.9s and 1.8s backoff**. Repeated bad frames do not
  restart that timer or consume another attempt. Same-subject loss gets a
  **1.5s** grace window. Persistent unusable motion exits recovery after **4s**.
  Lost/invalid targets or exhausted retries enter rediscovery with a **2s**
  cooldown, then reset acquisition using a new observation, without an AI toggle.
- Retained tracking has a phone-only short reacquisition window. A matching
  localized detection must be unambiguous, confidently observed and spatially
  consistent. A different same-named person cannot inherit the old ramp. Sony's
  default tracker behavior and connectivity are unchanged.
- During zoom, actual field-of-view changes reproject the tracking seed through
  the existing preview orientation/aspect/mirror geometry. Modest tracked
  movement no longer fails merely because it differs from a frozen predicted
  center; actual body, head/joint and protected-crop containment still apply.
- Recovery recalculates remaining scale from desired/current subject dimensions
  and the measured current camera zoom. Small remaining corrections can finish
  below the initial 12% useful-zoom threshold while retaining the original
  required-framing contract. Device and detail limits still apply. Targets are
  fixed during each individual ramp, rather than changed every frame.
- READY retains a small position/size hysteresis envelope to absorb jitter.
  A meaningful change returns to aim/recovery. A position-only change at the
  achieved scale keeps the same shot and needs no extra zoom: after re-aiming,
  it enters fresh verification at the measured target. An invalid plan needing
  a wider/different shot returns to discovery instead of oscillating zoom.
- Pinch begins with an immediate manual cancellation, even before the first
  scale-change event. Manual zoom, camera/lens/mode changes and AI off retain
  their priority. Recovery cannot clear that latch. Explicitly selecting a new
  subject or starting a new AI session can authorize a new shot.

The camera still uses `lockForConfiguration`,
`ramp(toVideoZoomFactor:withRate:)`, `cancelVideoZoomRamp`, and polling of actual
`videoZoomFactor` / `isRampingVideoZoom`. Display and native factors remain
separate. Verification-only recovery uses the same motor observer to obtain
fresh actual readings without issuing another ramp. Obsolete motor generations
cannot interrupt a newer retry. API acceptance is not treated as motor movement.

READY still requires fresh paired frame telemetry, fresh live camera readings,
the same subject, correct subject size/position, safe protected regions, actual
target zoom within 2%, stopped motor and final capture dwell. No timer alone
creates success. No SwiftUI preview scaling or automatic shutter was added.

The original timestamped pre-zoom preview is retained across retries of the
same plan. The paired capture payload updates to the resumed execution target,
retains the original wide zoom/time metadata, and requires fresh verification
before the user's shutter press. New scene/manual cancellation clears it.

## Diagnostics and verification

The existing exportable trace now also records retry count/deadline, recovery
states, gross-motion permission and recovery/rediscovery events. It continues
to report required gates, state durations, frame/live/native zoom, target and
selection reason, subject geometry/errors, tracking identity/confidence,
measured rotation/acceleration/age, crop permission, motor start/movement/target,
and final verification. Missing measurements are `unknown`, not invented.

The final suite runs **254 portable XCTest cases**, including **25 new
continuous-recovery cases**. They
cover all twelve requested scenarios, including four minutes of controlled
continuous attempts, multiple completed shots, bounded retries, same-subject
reacquisition, actual-value prerequisites for READY, same-zoom re-aiming and
paired-preview retention. These are controlled inputs to production Foundation
code, not replayed Vision inference, actual motor readings or real-device tests.

Commands:

```sh
python3 scripts/test_framing_portable.py --swift /tmp/focal-swift/usr/bin/swift
python3 scripts/validate_structure.py
```

All **123 app/test Swift files** also pass Swift frontend syntax parsing.
The project registers **494 native XCTest functions**. The portable runner
cannot type-check Apple SDK adapters or run AVFoundation, Vision or SwiftUI.
An Xcode build was attempted but `xcodebuild` is absent (exit 127). Full native
build/tests/archive and physical acceptance remain pending.

## Changed files

- `Focal/Composition/FramingPlanner.swift`: continuous transitions, backoff,
  timed recovery/rediscovery, same-scale re-aiming and final revalidation.
- `Focal/Composition/FramingProgress.swift`: gross-motion policy and recovery
  instructions; `ShotReadiness.swift`: explicit nonterminal trace states.
- `Focal/Composition/AutomaticShotPlan.swift`: safe moving-subject checks,
  small remaining corrections and READY retention hysteresis.
- `Focal/Camera/CameraController.swift`: wire existing actual zoom execution,
  separate manual cancellation, retry from observed zoom and export diagnostics.
- `Focal/Camera/SubjectTracker.swift`: phone-only localized reacquisition grace.
- `Focal/Composition/AutomaticGuidance.swift` and
  `Focal/Camera/CameraGuidanceCard.swift`: meaningful existing-card states without
  the blocking stability title. Camera layout/components are preserved.
- `Focal/Camera/ShotCaptureSession.swift`: keep original wide preview/metadata
  across retry and require renewed capture eligibility.
- `FocalTests/ContinuousFramingRecoveryTests.swift`, the portable runner,
  deterministic project/structure scripts, generated project, version labels,
  README and validation evidence.

## iPhone 16 Pro Max acceptance still required

Build latest `main` with Codemagic `ios-sideload`, then install its IPA over
Focal using AltStore. Confirm **Focal 2.8.0** in Camera Settings. With AI Guidance
and Automatic Zoom enabled, select a seated person, follow the directional aim,
and observe the live view and actual zoom readout tightening. Keep the subject
visible through a lean/brief movement and a temporary loss. The app should
recover without an AI toggle, stop at safe framing, and report READY only after
verification. Test another scene, already-good framing, manual pinch, AI off,
and manual shutter/paired save, including RAW where supported. Check real
handheld threshold behavior, thermal performance, transitions between lenses,
crop safety and ramp smoothness. A reference app's 2.2× is not an acceptance
target; measured framing and safety determine the required factor.

For evidence, open **Menu → Camera Settings → Developer Intelligence Lab →
Prepare AI framing trace → Share** after testing. The current sideload workflow
already includes trace export. Inspect actual `ZOOM_REQUEST`, `ZOOM_ACCEPTED`,
`MOTOR_MOVED`, `MOTOR_AT_TARGET`, `ZOOM_COMPLETE` and recovery events. A screen
recording alone cannot validate configuration locks or motor telemetry. No
physical iPhone verification is claimed for this change.
