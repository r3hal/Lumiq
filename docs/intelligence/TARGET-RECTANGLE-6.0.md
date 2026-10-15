# Focal Composition Engine 6.0 — app 2.7.1 / build 29

## 1. Reference comparison and confirmed root causes

The supplied screenshots and two MP4s were studied as behavior references. The 4.900-second classroom recording shows a small chair region selected in the wide view, a directional cue, alignment, then a substantially tighter view with displayed zoom changing from 0.5× to approximately 2.5×. The 8.267-second Focal cat recording shows persistent detection at 1.8× while guidance alternates between holding and paused.

The screenshots distinguish a selected source region from the intended final photograph. They do not reveal the reference app's models, internal object/part boundaries, server use, crop constraints or lens policy. Focal implements independent measured geometry and local heuristics. It does not copy the reference's interface, branding or assets, and it does not assume every target should use 2.5×.

Actual gaps found in Focal:

- The executable `AutomaticShotPlan` was created only after alignment. There was no persistent executable target rectangle while the photographer was trying to aim.
- The old fitness function penalized subjects below a small visibility threshold, but gave many larger subjects full scale fitness. A cat occupying 15% could already exceed that threshold, so a useful pet portrait was rejected even though the desired subject prominence was much higher.
- Crop search primarily evaluated camera-centered crops, which limited discovering an off-center photograph before panning toward it.
- Every surrounding detection/enclosing rectangle could become mandatory protected context, including unrelated furniture. That can prevent isolating a selected subject.
- Preview/detail limits could leave only a jump to a physical lens stop beyond the current zoom. Missing intermediate quality-bound candidates can mean no safe tighter shot is offered.
- Aiming stability and readiness used the same practical framing gate. They now have distinct purposes and thresholds.

The preceding release's fixes for hold starvation and one-sample cancellation remain. The recording alone cannot establish which specific sensor, override or device gate fired on that phone.

A separate build-27 error was also found: `framingInstruction` had accidentally been passed to `ShotReadiness.permitsReady`, whose signature does not accept it, rather than to `AutomaticGuidance.update`. This update fixes that call and adds an integration check. The previous portable subset did not compile the Apple controller; its passing results were not evidence of a successful iOS build.

## 2. Modified files

- `Focal/Composition/TargetRectangleGeometry.swift` and `TargetRectangleSearch.swift` — new normalized geometry, measured crop ranking and bounded quality policy.
- `AutomaticShotPlan.swift` — selection-time plan, desired rectangle, camera-image geometry, persistent identity and execution rebasing.
- `SceneCompositionPlanner.swift`, `IntentCompositionSearch.swift` — integrate useful target candidates with the existing composition library; retain legacy environmental/manual planning.
- `FramingPlanner.swift`, `ShotReadiness.swift` — persistent selection, separate capture stability, measured wide-scene readiness, explicit recovery/canceled/failed states and strict completion.
- `PreviewProjection.swift`, `CompositionEngine.swift`, `CompositionOverlay.swift` — shared coordinate conversion and original Focal planned-frame presentation.
- `AutomaticGuidance.swift` — correctly route actual stop reasons and gate scene readiness.
- `Focal/Camera/CameraController.swift`, `SubjectTracker.swift` — connect selected plans to the existing AVFoundation ramp and stable tracking reference.
- `FocalTests/TargetRectangleDirectorTests.swift` — 25 new regressions. `IntelligenceAcceptanceTests.swift` uses normalized containment for its fractional-crop assertion.
- Project/generator, portable runner, structural validator, settings/version and evaluation metadata, README/validation/report.

Sony connectivity/protocol files and the existing user-only shutter, photo/RAW capture and paired storage architecture were not changed.

## 3. Persistent ShotPlan architecture

The existing `AutomaticShotPlan` now exists at shot selection, before aiming. The existing `FramingPlanner` retains it; there is no second camera session or competing zoom controller.

It contains a stable ID, selected subject label and tracker reference, selection confidence, observed subject bounds, desired final subject bounds/position/scale, source composition rectangle, target zoom, device limit, observed protected head/joint/context regions, composition type/kind, relative quality score and selection reason. `ShotImageGeometry` records normalized oriented camera-image geometry at selection. `FramingPlanner` owns the current status and live confidence/error comes from fresh analysis, rather than pretending the original confidence remains current.

`selectShot` retains a healthy tighter plan through aiming. `prepared` rebases the execution origin after the user aims, preserving the ID, intended final bounds and selection rationale. It recalculates the required zoom from current measured width and height, checks feasibility and protects the observed regions before commanding the motor. It does not invent a new composition every frame.

The progression is discovery/candidate evaluation → selected shot → aiming → aligned hold → actual zoom → composition verification → READY. RECOVERING retains the selected plan within bounded limits. Manual/disabled cancellation and hard failures have distinct terminal status/reasons.

## 4. Target composition calculation

The existing composition library remains. New candidates compare a measured current/environmental frame with feasible tighter pet, person, face-region or object portraits. A detected face region can be a face portrait anchor; an unobserved animal head, eyes or furniture part is never fabricated. Whole detected bodies/objects remain protected by default. The screenshots cannot establish how the reference chooses a chair backrest detail, and Focal does not pretend a generic object box supplies verified part segmentation.

A subject-specific area preference supplies a continuous scale estimate. For example, a pet portrait prefers about 44% subject area when feasible. Both width and height constrain the fit, with margins. Device limits, existing intent limits, source visibility, measured light clipping and context can select a gentler crop or the original frame instead.

Each target crop is a known region inside the observed image. Its normalized width and height are `1 / scale`, so its pixel aspect matches the selected capture aspect. Crop origin follows the desired final subject position. Near an image edge, the crop stays inside observed pixels and its final subject position is derived from that clamped region; this preserves a useful off-center portrait instead of rejecting every modest crop. Candidates are scored using measured prominence, boundary completeness, balance, observed background edge density, light clipping and a crop penalty. A minimum gain avoids unnecessary zoom on an already strong portrait. These are transparent heuristics, not a trained aesthetic probability or proof of the best photograph in a scene.

Meaningful nearby people/pets retain the existing environmental/group path. An incidental chair does not force a cat portrait to preserve the entire room. Existing environmental techniques still protect intentional context. Wide landscapes/architecture can receive an explicit scene-anchor plan with no zoom; readiness requires fresh textured scene evidence, confident classification, measured light and capture stability.

Intermediate quality-bound scale candidates are included. The additional detail allowance is an estimate from configured photo dimensions (8 MP retained-pixel budget), preview dimensions (960-pixel short-side budget), existing limits and the existing conservative cap. Physical lens stops remain separate. This policy does not certify true sensor detail or make intermediate zoom optical. Actual preview quality and lens transitions need hardware testing.

## 5. Coordinates, overlay and guidance directions

Canonical geometry uses normalized **oriented camera-image coordinates**, top-left origin and unmirrored. This is not a world coordinate or a claim to know raw sensor geometry before orientation. The existing app is portrait-only; its AVFoundation connections rotate the output into the portrait image used by Vision. Arbitrary landscape UI rotation was not added.

`visibleVisionRect` converts Vision's bottom-left coordinates and then applies the existing aspect-fill/mirror projection. `imageRect` is the inverse mapping back into the oriented image. Aspect-fill and mirror round trips are tested.

For sensor-centered zoom with final desired subject position `d` and remaining scale `s`, the pre-zoom aiming point is `0.5 + (d - 0.5) / s`. The current subject center minus that point supplies pan/tilt error. The existing `CompositionCue` accounts for preview aspect and mirrored physical pan direction. Existing temporal recommendation memory suppresses opposite-direction flicker.

Focal retains its own subject corners and camera layout. A restrained dashed **Planned frame** boundary distinguishes the intended source photograph from the detected subject box. It follows measured frames and expands toward the visible frame as actual zoom is observed. It is an overlay, not simulated camera magnification. Direction arrows stop during zoom/verification and disappear on completion. Optional target dragging/resizing was deferred while physical core verification remains outstanding; existing tap selection and return to a new automatic AI session remain.

Normalized containment now uses direct bounds comparisons with a 1e-9 rounding allowance. Linux Swift Foundation's CGRect containment can reject an interior rectangle at fractional coordinates due to union rounding. This mathematical correction preserves the much larger photographic crop margins; it is not evidence that this platform-specific issue caused the recorded iPhone stall.

## 6. Real automatic zoom execution

The same `CameraController` camera queue calls the active `AVCaptureDevice.ramp(toVideoZoomFactor:withRate:)`. Before execution it checks activation generation, manual override, fresh observation, active camera/capture state, thermal state and hardware limits.

The target comes from desired subject width/height relative to the current measured bounds. Displayed zoom is converted to native device units using the existing virtual-camera multiplier and supported min/max/active format limits. No fixed 2.5× target or SwiftUI preview scaling is used.

The existing staged ramp, 50 ms actual-factor polling, movement watchdog, analysis watchdog and overall deadline remain. Optional earlier-wide JPEG encoding is dispatched after the motor command has been queued, so it does not delay command dispatch. Accepted commands are not treated as proof of movement.

Aiming uses fresh Core Motion under the practical 0.22 rad/s / 0.08 g framing gate. Capture readiness uses the stricter existing 0.12 rad/s / 0.04 g gate. These policy values remain subject to physical-device tuning. Small subject motion is measured separately from phone motion and does not continually restart a valid aligned hold.

## 7. Tracking during zoom

The existing Vision object tracker remains responsible for the selected ROI. A stable tracker reference distinguishes even two subjects with the same label. Healthy tracking is retained during aiming and zoom; expensive semantic rediscovery does not switch targets mid-shot. Reseeding for field-of-view changes preserves the reference.

Current device zoom reprojects the prior measured ROI before tracking the new frame. Head/joint geometry that was actually observed is carried affinely with the tracked body through aiming and zoom; stale pose inference does not silently erase that protection. This is tracked geometry, not new eye/pose recognition.

Brief tracking, motion or freshness problems pause the real motor and retain the same target. The preceding bounded recovery budget, good-observation dwell and manual priority remain. A changed tracker reference, unsafe crop, failed command or expired recovery cannot become READY.

## 8. READY and shutter behavior

A tighter selected plan cannot use the measured-current-frame shortcut merely because the object is centered. Completion uses one geometric error definition: position within 0.05 normalized aspect-correct distance, width/height within 8%, actual zoom within 2%, motor stopped, valid subject identity/confidence, fresh observations and safe protected regions. A new continuous verification dwell is required after a composition mismatch. Capture stability is required for that dwell.

An already good frame or wide scene can finish without zoom only through the explicit measured-current-frame/scene path. Stop reasons are routed to the guidance API, including when Automatic Zoom is disabled.

The user owns the shutter. No photograph is taken at discovery or on READY. One user press still uses the existing camera photo output. Final processed framing, optional RAW, review and the optional earlier low-resolution wide preview continue through the existing library. The earlier preview is not a second full-resolution photograph. Physical preview/photo matching, including RAW/review behavior, remains a device acceptance item.

## 9. Tests and diagnostics

Executed on Linux with Swift 6.0.3: **197 XCTest cases passed, zero failures**, including all **25** existing scene-planner cases and **28** target-rectangle cases. The runner now compiles the actual pure selection/planning/reasoning/readiness stack, not just the earlier small ramp subset. Apple pixel adapters, SwiftUI, Vision runtime and AVFoundation hardware calls are excluded. Supporting photo measurement data/luma code is copied verbatim; no fake camera substitutes for device validation.

New tests cover cat prominence above the old minimum, chair selection before aiming, persistent plan IDs, full cat plan→aim→zoom-observation→verify→user-capture-payload flow, chair native command geometry, no premature READY, separate stability gates, target locking, same-named identity changes, crop/aspect/mirror transforms, already-good framing, known-source boundaries, group/context preservation, intermediate quality budgets, unavailable anatomy, tracked head protection, target rectangle through zoom, terminal states, scene readiness and correct reason routing. Existing acceptance/refinement tests also run. One existing fractional-crop assertion now uses the same explicit normalized containment operation as production.

Swift frontend grammar parsing passes for **118 Swift files**. Structural checks pass: 89 app / 29 test sources, **437 total registered XCTest functions**, deterministic project, resources/configuration, frozen baselines, unchanged Sony sources, user-only shutter wiring and the controller/readiness argument contract.

The supplied Codemagic run for build 28 compiled the app and executed 434 native tests: 432 passed; the enclosing-frame and group-triangle scene-planner tests failed. Those exact failures were reproduced locally after adding the unchanged `SceneCompositionPlannerTests.swift` suite to the portable runner (194 cases, two failures). After the correction and three additional tests, all 197 portable cases pass. Xcode is unavailable in this Linux workspace. The updated 437-case native suite and device archive require a Codemagic rerun; portable tests and syntax parsing do not replace that check.

### Build 29 regression correction

The new tighter-portrait search previously omitted enclosing-frame evidence and only protected nearby human/pet companions. As a result it could override the environmental planner's enclosing-frame or mixed-object triangle composition. The environmental planner and target search now share frame validation and the existing measured three-point-arrangement check. The controller passes real enclosing-frame observations to direct target planning as well as full composition planning. In these cases the environmental composition remains authoritative; no synthetic zoom or message-only workaround is added.

Three additional tests cover enclosing-frame retention through both planning paths, a named-chair/mixed-subject triangle, and invalid/unrelated/too-small rectangles that must not suppress useful zoom. Existing cat-with-background-chair, pet companion, aiming, zoom progression, crop safety and manual override cases continue to pass. The original two failing assertions are unchanged. No Sony connectivity or UI behavior changed; the settings version label is updated.

Development/evaluation logs now include plan/tracker identity, current/desired/canonical source rectangles, relative score/type, alignment/width/height/zoom errors, displayed/native/target-native factors, motor state, confidence, rotation/acceleration/age, aiming versus capture stability, permission/quality limits, state/block reason, recovery and ramp start/pause/resume/completion/cancellation. They remain development-only.

## 10. Physical iPhone 16 Pro Max acceptance

Build `main` with Codemagic `ios-sideload`, install the successful 2.7.1/build 29 IPA through AltStore. Set the starting zoom first, then enable AI Guidance with Automatic Zoom and Subject Tracking. Manual zoom after enabling AI deliberately overrides it; toggle guidance off/on to start a new shot.

Test the cat under the table and an isolated chair: selected source frame is distinct from the subject box, directional cues guide aiming, alignment starts actual smooth zoom, the number/FOV changes, tracking survives, and READY follows completion. Compare final saved framing with the preview. A quality/device limit must result in an explicit reason or justified wider plan, not a fabricated target achievement.

Check slight pet motion, brief occlusion, stronger phone movement, person/face tracking, a second same-named subject, 0.5×/1×/1.8× starts, physical lens transitions, mirror/aspect choices, manual pinch/lens/mode changes, AI off, background/interruption, low light and hot-device limits. Check already-good portraits and wide scenes without unnecessary zoom, no oscillation after READY, one user shutter press, RAW/review, paired preview labels and export/relaunch/delete.

No physical iPhone validation is claimed. There is no new learned aesthetic model, verified arbitrary object-part segmentation or promise to recognize every possible object. The references establish the interaction; hardware testing establishes whether the implemented camera behavior meets it on this phone.
