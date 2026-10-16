# Focal AI improvement plan

The visual comparison and pinned current-source audit were completed before implementation. This plan uses independent engineering and user-provided runtime evidence, not Framed code, models, assets or presumed proprietary algorithms.

## Focused implementation priorities

The P0/P1 changes below have been implemented on this branch in the existing camera and composition pipeline. New regression cases are registered; execution awaits the native Codemagic test run. A source reviewer checked the manual-layout target and lens reconfiguration wiring. The changes are not a claim of physical-camera verification.

1. P0: Preserve enabled director state after explicit lens selection; keep new-lens geometry fresh, keep motor grace, preserve controls and manual shutter.
2. P0: Allow aligned, safely measured manual Thirds/Center layouts to satisfy current-frame verification without a tighter-crop plan or automatic zoom. Reject stale/unsafe/low-confidence/moving frames and require a bounded hold.
3. P0/P1: Bound current-frame confirmation gaps; separate benign temporary ineligibility from actual identity/crop loss if a safe retention contract can be established. Do not keep a green state through missing/unsafe evidence just to match Framed's UI.
4. P1: Make whole-scene instructions and READY agree on radial alignment. Reset candidate-switch dwell after evidence interruption; retain explicit alternatives while supported.
5. P1: Honor manual acquisition grace, prevent canceled optional Vision batches from starting fallback work, bound optional work using frame age, and reject stale frame-derived publication on the main queue.

Manual zoom keeps AI Guide active and suppresses automatic zoom during the existing three-second grace. After that grace, automatic composition may resume; the user’s zoom is respected as the new observed framing, and the photographer can keep adjusting it. Device testing must confirm this feels responsive and never fights an active gesture.

No broad rewrite; preserve existing detector, coordinate system, motor safety, selected-subject AF, Sony control/Live View/capture, effects/editor/gallery. No external-camera zoom. No readiness-driven shutter trigger. Tests go into existing registered XCTest files and portable production-source harness where possible.

## Photographic composition coverage

| Requested opportunity | Current evidence or route | Next evidence needed |
|---|---|---|
| Thirds, golden ratio, negative space | Subject geometric candidates; measured warm-color thirds | Labeled final photos and intentional off-center subjects |
| Leading lines, vanishing points, diagonals | Long supported pixel edges and interior convergence | Real forest paths vs unrelated branches/trunk grids |
| Tree symmetry, repeating trunks | Whole-scene mirror/periodicity heuristics | Shifted tree axes, uneven trunks, seasonal forest scenes |
| Foreground/midground/background | Lower/upper texture contrast; no metric depth | Human-labeled depth layers and clutter rejection |
| Natural frames | Enclosing rectangle candidates for selected objects; no curved arch segmentation | Branch openings and irregular natural frames |
| Autumn color, leaves, textures | Warm/cool centroid, texture and generic classification | Real foliage/detail evidence; no species claim |
| S-curves | Library/manual concept; no automatic curve detector | Annotated path/stream curves and hard negatives |
| Backlight, silhouettes, fog, sun rays | Generic measured exposure/highlight advice only | Intent-labeled scenes; exposure conservation vs deliberate silhouette |
| Reflections, streams/water | No verified dedicated semantic detector | Paired reflection boundaries and water hard negatives |
| Mushrooms/small details | Generic localized recognized-object route, capability unverified for these classes | Actual model labels/confidences and close-focus tests |

Keep no-person/animal whole-scene operation. Do not call symmetry “trees,” convergence “path,” or warm color “leaves” without supported recognition. Offer explicit alternatives with score-margin/dwell retention. Do not add imagined forest detections to satisfy a checklist.

## Verification per fix

| Fix | Focused regression | iPhone verification |
|---|---|---|
| Lens/zoom continuity | Controller route guards; manual activation/grace policy fixtures | Pinch and every preset/lens during search, refinement, READY; no off/cancel, no gesture fight |
| Manual layout READY | Aligned Thirds/Center, off-target, unsafe crop, stale/low confidence/motion fixtures; no motor | Normal handheld subject, auto-zoom disabled; READY after achievable hold |
| Hold/recovery | Frequent vs widely spaced/repeated/backward samples; immediate safety invalidation | Brief motion and subject loss/reappearance without toggling AI |
| Outdoor alignment | Diagonal dead-zone invariant in all quadrants, mirrored pan, aligned no action | No-person warm-color and converging-line scenes |
| Candidate retention | Challenger, evidence outage, renewed dwell; explicit alternative | Small pans in autumn forest, retain useful composition |
| Inference/publication | Cancellation/deadline policy and integration guards; age after queue hop | Frame-age logs, processing latency, thermal state, zoom gesture traces |

## Required new device evidence

Record current build/commit on iPhone16 Pro Max; show gestures with an external camera or visible touches. Synchronize a local debug framing trace with video. Include static/tripod vs handheld, rapid pan/loss for .5/2/5s, returning subject, two people crossing/printed portraits, manual focus/exposure, virtual and physical lens switching, front mirroring, interruption/background, capture/save, Sony A7 III connection/Live View/remote shutter, and any separately available Fujifilm integration. Take every photo manually.

For forests record path/convergence, repeated and symmetric trunks, foreground leaf/mushroom, branch opening, negative space, stream/reflection, fog/backlighting and sun rays. Include controls with no strong composition cue. Save source frames and human-rated acceptable alternatives. Compare final photographs as well as preview UI.

Measure time to first useful advice, direction reversals, plan/subject switches per minute, time in each recovery state, READY reachability/retention, stale rejection rate, analysis mean/p95, frame-to-guidance age, focus continuity, thermal behavior and motor interventions after manual input. Target values require a measured baseline; none are claimed from synthetic fixtures or these short historical clips.

## Build and physical validation

Use the dedicated branch with Codemagic `ios-check` to execute native XCTest; `ios-sideload` additionally archives the unsigned iOS build. Existing portable harness can execute production Foundation logic when Swift is available. Windows structural/source checks do not establish Swift compilation, Vision/AVFoundation behavior or physical photographic quality. Test results must name every unexecuted layer.
