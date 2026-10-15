# Focal 2.11.0 / build 37 — continuous guidance and measured outdoor compositions

Follow-up: [build 38 corrects the scene-only READY presentation shortcut](READY-PRESENTATION-REGRESSION.md), preserves the original object-confidence assertions and expands the portable test selection. The build-37 validation below describes that release's checks, not a passing native test suite.

## What failed

1. `CameraController.cancelZoomRamp(manualOverride:)` set **both** a persistent motor block and `automaticShotArmed = false`, then stopped the director with `.manualControl`. `beginManualZoom` and both coalesced `setZoom` stages also reset framing with `enabled:false`. Nothing released that latch after a pinch. The preview had a pinch-begin callback but no matching controller end callback.
2. `setIntent(.landscape)` reset framing to disabled because landscape forbids automatic zoom. Environmental pet framing did the same. A restriction on zoom had incorrectly become a restriction on guidance/readiness.
3. `SceneCompositionPlanner.update` required an object rectangle; its subject comparison returned no candidates for landscape intent. The older whole-scene fallback needed a landscape classifier result and capture-level stability. A forest with visible structure but no named subject could remain searching.
4. Even after selecting a whole-scene shot, the controller passed its absent object bounds into `FramingPlanner.update`. That object-loss path could initiate recovery before the wide-frame confirmation completed.
5. Capture completion resumed analysis but retained the previous completed plan. It did not explicitly begin a fresh composition evaluation.

These are code-path findings. No new physical-phone recording or device trace was available for this task, so they are not a claim to have diagnosed every possible field failure.

## Implemented behavior

### Manual zoom and continuity

- The existing hardware zoom path remains: coalesced pinch/lens requests and AVFoundation device zoom/ramping. No SwiftUI preview scaling or duplicate zoom controller.
- `ManualZoomGrace` suspends only automatic motor commands throughout a pinch and for **three seconds after it ends**. Lens-button requests extend the same grace from the latest request. Repeated input invalidates older resume callbacks.
- Gesture end, cancellation, failure and preview dismantling notify the controller. A long pinch cannot outlive a timer and accidentally let AI fight it.
- Analysis and guidance continue while the motor is suspended. Manual-zoom delay is no longer a reason to suppress scene/object discovery. Existing motion/thermal/admission safety remains.
- Reproject the retained native tracking rectangle using the observed old/new zoom ratio. Update its coordinate baseline immediately, so successive zoom changes do not repeatedly apply an old scale. `SubjectTracker.reseed` preserves its existing identity. Subject autofocus is not reset by the manual replan helper.
- If the subject actually leaves the new field of view, discard its invalid rectangle and allow existing automatic selection/recovery to find another. Old crop verification and paired-wide eligibility are invalidated when framing changes; stale geometry is never called verified.
- On grace expiry, require fresh evidence and a safe plan. Do not disturb an already verified good current frame. AI OFF and Automatic Zoom OFF remain respected.
- Landscape and other nonzooming intents can guide and verify a wide frame. Turning Automatic Zoom off no longer disables the guidance director; candidate scales are restricted to the current view.
- Existing bounded tracking-loss/ramp retry/reacquisition logic remains. After a user-triggered capture completes, clear obsolete composition verification and evaluate the next shot while retaining valid subject tracking.

### Forest/landscape opportunities without a named object

`OutdoorCompositionPlanner` is a bounded branch of the existing scene planner, not an independent subject tracker or cloud model. It reads the existing aspect-fill/orientation/mirroring-correct visible pixel evidence.

It can rank up to eight distinct techniques, when their evidence exists:

| Opportunity | Actual signal | Limitation |
| --- | --- | --- |
| Balanced wide frame | Image variance and clipping | A conservative composition suggestion, not an aesthetic verdict |
| Symmetry | Existing mirrored pixel similarity with contrast | Does not identify a tree tunnel |
| Repetition | Existing periodic image structure | Does not identify the repeated species/object |
| Diagonals | Long supported diagonal segments | Keeps actual visible geometry |
| Converging lines | Nonparallel supported diagonals that approach an in-image intersection | A grid crossing alone is rejected; not a 3D depth estimate |
| Color contrast / thirds | Weighted warm-color centroid versus the scene | Warm color is not a claim to recognize autumn foliage |
| Layered layout | Different lower/upper texture and contrast | No foreground distance or physical depth is measured |
| Candidate horizon placement | Existing long horizontal boundary | Guidance explicitly asks the photographer to confirm it is a horizon |

No object box or fake object confidence is created for a scene. The existing visual language displays its composition name and, when needed, a small target mark and aiming line tied to the measured feature. Mirrored previews reverse physical horizontal pan instructions.

Candidate hysteresis retains supported choices through small score changes, waits 1.4 seconds before accepting a stronger challenger, and avoids switching thirds after a small pan. It updates geometry from current evidence. A choice whose evidence disappears is released. Candidate arrays are bounded and cached per evidence timestamp.

**Try Another Composition:** long-press the existing yellow AI button and choose the action. It cycles to a different supported technique without switching AI off; it holds the explicit choice for four seconds while still supported. It also prefers a distinct layout among existing object candidates. If only one safe option exists, it keeps that option.

### READY and safety

- Wide-scene READY requires fresh plan/image evidence, useful visible variation, acceptable clipping, alignment within 0.10 normalized units and the existing gross-motion framing gate. It uses a 0.5–0.7-second confirmation, rather than capture-level stillness. Mild handheld motion can pass; fast movement cannot. READY is a composition assessment, not a guarantee of focus or a blur-free exposure.
- Whole-scene plans bypass the object-loss/motor gate. They preserve the whole observed view at the current zoom; they do not invent a tighter forest crop.
- Object auto-framing still requires its real selected identity, crop safety, device-supported zoom, actual motor feedback and final verification. Those checks were not replaced with a timer or cosmetic READY message.
- Current scene pixels prioritize significant highlight clipping or very low light over aiming/READY advice.
- Existing one-in-flight preview admission, asynchronous Vision work, stale-result rejection, coalesced zoom input and thermal throttling remain. No measured FPS, thermal, memory or battery improvement is claimed.
- The shutter remains exclusively user-triggered. Paired capture policy is preserved; field confirmation of actual saved files is still necessary.
- **All `Focal/Sony` production files are unchanged.** No remote zoom was added. This checkout contains no Fujifilm implementation to modify or physically validate.

## Deferred rather than fabricated

No new validated detector for mushrooms, moss, rocks, species, logs, forest trails, curved paths/S-curves, streams, waterfalls, fog, sun rays, rim light, reflections or physical scene depth was added. Existing named-subject recognition and the 22-technique field guide remain; educational techniques are not automatically promoted into detections. Natural-frame/object-context reasoning still needs its existing observed subjects/rectangles. A golden-ratio position is not presented as a detected spiral.

The new candidates are local heuristics. Their numerical scores are rankings, not calibrated probabilities or proof of the best possible photograph. Validate them on real forest scenes before relying on them for the outing.

## Files changed

| File | Change |
| --- | --- |
| `Focal/Camera/CameraController.swift` | Nonterminal manual motor override, grace expiry, FOV rebasing, scene readiness/motor separation, new-shot evaluation after capture, alternative action and diagnostics |
| `Focal/Camera/CameraPreview.swift` | Pinch-end/cancel/dismantle callbacks |
| `Focal/Camera/CameraView.swift` | Wire callback; long-press alternative; composition label and measured scene overlay input |
| `Focal/Camera/CameraGuidanceCard.swift` | Present verified scene READY without an invented object box |
| `Focal/Composition/ManualZoomGrace.swift` | New pure timing/reprojection policy |
| `Focal/Composition/OutdoorCompositionPlanner.swift` | New measured whole-scene choices, geometry, hysteresis and eligibility |
| `Focal/Composition/SceneCompositionPlanner.swift` | Integrate subjectless/landscape branch and explicit distinct alternative selection |
| `Focal/Composition/AutomaticGuidance.swift` | Scene aiming/lighting/verified READY advice |
| `Focal/Composition/CompositionOverlay.swift` | Reuse existing aiming line style for actual scene anchors |
| `FocalTests/OutdoorGuidanceTests.swift` | 27 new policy/geometry/readiness/guidance/presentation regressions |
| `scripts/test_framing_portable.py` | Execute new production logic/tests, unchanged preview policy tests and presentation enum on Linux |
| `scripts/validate_structure.py` | Protect Sony scope, register 607 native tests, check actual gesture/capture/scene wiring |
| `scripts/generate_project.py`, `Focal.xcodeproj/project.pbxproj` | Register new sources/tests; version 2.11.0 / build 37 |
| `README.md`, `VALIDATION.txt`, this report | Current behavior, evidence and limitations |

## Validation

- **318 portable framing/session/subject-autofocus/presentation/preview-policy XCTest cases passed**, including 27 new outdoor/manual-zoom cases and four previously native-only preview-policy cases. The runner compiles production algorithm files; it extracts pure supporting declarations and excludes Apple image/thermal adapters. These tests do not execute `CameraController`, Vision, SwiftUI or a real zoom motor.
- **75 Sony protocol/settings tests passed** against scripted camera responses, including the previous confirmed-state/polling repairs. No physical Sony commands were issued.
- **135 Swift files passed frontend syntax parsing.** This does not type-check Apple framework APIs or build the app.
- Structural checks passed: deterministic 99 app/36 test source references, 607 registered native XCTest functions, baseline hashes, resources/YAML, scope, source integration guards, manual-only shutter and whitespace.
- `xcodebuild -version` failed with **command not found / exit 127**. No native iOS build, native XCTest suite, archive, hardware zoom or outdoor performance result is claimed.

Commands: `python3 scripts/test_framing_portable.py --swift /tmp/focal-swift/usr/bin/swift`, `python3 scripts/test_sony_portable.py --swift /tmp/focal-swift/usr/bin/swift`, `python3 scripts/validate_structure.py`, and Swift frontend `-parse` over all app/test sources.

## Physical iPhone 16 Pro Max acceptance before Sunday

1. Run Codemagic `ios-sideload` from latest `main`; all 607 native tests and the archive must succeed. Install build 37 with AltStore.
2. With AI ON, repeatedly pinch and tap lens buttons around a selected person/cat/object. Confirm guidance stays on, AF follows the same visible subject, the motor stays cancelled throughout the gesture plus three seconds, and any later automatic ramp is smooth/safe. Check manual focus and Automatic Zoom OFF.
3. Zoom until the old subject leaves the image. Confirm automatic rediscovery without toggling AI. Check motion, exposure adjustments, background/foreground and lens changes.
4. Try a forest without people/animals in Auto and Landscape: patterned trunks, a path with converging edges, warm foliage, a wide canopy and a blank/very dark scene. Check supported choices, correct aiming directions, no invented species and achievable wide-frame READY. Long-press AI for another composition and check it remains stable during small pans.
5. Let a small named subject auto-frame. Confirm the actual preview/zoom reading changes, important regions remain visible and READY follows real completion. Manually take a photo; verify paired saving and immediate next-shot analysis.
6. Run a sustained outdoor session, watch delivered cadence/thermal state and check memory/battery with device tools. None of these measurements can be supplied by Linux tests.
7. Export the existing framing diagnostic log from Developer Intelligence Lab if needed. New `MANUAL_ZOOM_BEGIN`, `MANUAL_ZOOM_END` and `MANUAL_ZOOM_GRACE_ENDED` records accompany existing shot/motor/recovery traces. Timestamps/revisions are real runtime values, not simulated evidence.
