# Focal Intelligence 2.0 — Focal 2.2 / build 19

This extends the existing SwiftUI app and iPhone/Sony camera services. It does not replace AVFoundation capture, the native preview, RAW/manual controls, gallery, automatic lens ramp or manual cancellation. The AI is an independent explainable engine around Apple's native models; no proprietary Framed implementation or private model is used.

## 1. What was wrong

The previous detector could identify useful subjects, but its photography decisions were mostly fixed thresholds and technique bonuses. It lacked a measured keep-current-frame candidate. Large but fully contained cats could trigger Step back. Texture could trigger isolation advice, and class-name tips could demand unobserved pose changes. Message debounce did not examine action outcomes. Offline Insights repeated separate generic advice. See [audit](AUDIT.md).

## 2. Root causes in actual code

Build 18 `AutomaticGuidance` treated width/height above 0.85 as a framing failure, regardless of margins or intent. `SubjectIdentity.tip` generated class-specific directions without anatomy. `PhotoMeasurements.clutterAdvice` used global outside-subject edges, which cannot distinguish clutter from fur, bedding or structural detail. `SceneCompositionPlanner` ranked layouts without a current-frame baseline or meaningful improvement threshold. The new source replaces these decision paths; obsolete class tips remain only in compatibility/demo helpers and the frozen baseline, not the real guidance pipeline.

The frozen build 18 sources were captured before changing algorithms. Baseline commit: `beaced8242f97531bb54812850c0cf8a11922632`. Snapshot integrity was checked against that local source. Baseline XCTest assertions demonstrate the contained-cat, unobserved-eye-level and semantic texture-selection rules; their native execution remains pending.

## 3. Models and algorithms

Native Vision: human/face rectangles, cat/dog recognition, objectness/attention saliency, localized/global classification, rectangle/text recognition and object tracking. Conditional animal/human body pose is now sampled at most once per 2.5 seconds when relevant. Only confident visible joints are used; missing joints do not prove clipping. Matched animal head-joint envelopes and real detected faces provide a supported autofocus point and headroom when fresh; manual focus still takes priority. Animal pose is skipped in Simulator because Apple's sample specifies physical-device support.

No new Core ML weights, training pipeline, cloud service, API key or app dependency was added. Existing temporal acquisition/challenger selection and manual intent remain. Confirmed people/pets receive a smaller texture penalty, so fur/clothing/bedding cannot defeat strong native recognition; anonymous object proposals retain their stronger evidence requirements. Focal Intent controls category eligibility and the new framing profiles. Auto uses reliable category context but avoids specific pose/style assumptions.

`SceneAnalyzer` provides bounded single-image analysis using the same detector, selection, projection and assessment components as live iPhone/Sony frames. Single-image results cannot establish tracking or camera shake. `CompositionAssessment`, `IntentCompositionSearch`, `ActionFeasibility` and `RecommendationMemory` separate scene facts, candidate search, action support and temporal presentation.

## 4. Changes implemented

- A current-frame candidate wins when no reliably measured improvement reaches 0.08. Comfortable off-center placement is accepted; no universal thirds/center target is forced.
- Intent-specific size ranges and broad acceptable-position regions replace a universal small-subject threshold.
- Edges use actual visible fraction, minimum margin and supported joint-edge observations. Large dimensions alone no longer produce Step back.
- Crop candidates remain inside the observed image and retain the main subject, other relevant subjects and enclosing context. The candidate fitness uses visibility, margins, subject scale and acceptable-position penalties, with a crop cost. Texture is not treated as proof that a tighter crop is better.
- Size-driven crops preserve the measured placement instead of inventing an unrelated pan toward thirds. Only sensor-centered candidates with adequate improvement can map to a real phone zoom, including when layout planning is off or Center is explicitly selected. Existing hardware/detail/native-stop budgets, physical hold and pinch/lens priority remain.
- Unsupported isolation/angle/pose requests are withdrawn. Already acceptable framing can return Ready to shoot. Severe measured light/highlight issues can still produce specific advice.
- Memory records action, subject, intent, prior bounds/size, issue magnitude and time. Opposite directions require persistence and cooldown. Repeated worsening with actual position changes withdraws a direction for reassessment; it never claims the user caused a change or proved an improvement.
- Relative subject movement and fresh gyro stability suppress readiness/directional chatter. Loss hides stale indicators. Camera direction lines appear only for a supported direction decision.
- Live guidance, opt-in Coach, captured-image Insights and the developer evaluator share feasibility rules. No separate Coach instructions about missing hands or generic posture are generated.

## 5. New measurements

Visible subject fraction, frame area, minimum margin, size/position penalties, measured face headroom, confident joints near frame edges, head yaw where Vision supplies it, nearby named regions, subject/background color separation, outside edges and visual-mass offset. Landscape analysis uses scene-level rendered exposure and a long visible boundary's orientation, without an object box. Architecture records supported long-line lean where multiple vertical-like lines exist.

These values are exported in evaluation JSON; applicable face/margin/boundary/head-turn values also appear in Insights. Missing evidence is unavailable, not invented. Head yaw is not eye gaze. Visible edges/joints do not prove which hidden limb is missing. A long scene boundary is not necessarily a horizon. Line lean is not calibrated 3D perspective. Edge energy is not a reliable optical blur score; motion advice requires temporal/motion evidence rather than low texture alone.

Apple's [VNCalculateImageAestheticsScoresRequest](https://developer.apple.com/documentation/vision/vncalculateimageaestheticsscoresrequest) is queried only during stored-image analysis/evaluation, guarded for iOS 18+. Its [overall score](https://developer.apple.com/documentation/vision/vnimageaestheticsscoresobservation/overallscore) and utility flag are supplementary, optional results. They never create camera directions, select a crop or override human labels. Failure/unavailability leaves them absent.

## 6. Recommendation logic

Actions are structured: no adjustment, hold, make room, tighter crop, physical pan, level, protect highlights or add light. Confidence, frame geometry, actual exposure and intended composition determine feasibility. A proposed crop must improve the measurable current fitness and preserve important content; a pan must have explicit manual-target intent or a supported composition/crop issue. No unseen background or safe walking route is presumed. Vague Isolate the subject is not a real guidance action.

No-change results immediately withdraw stale pan advice. Opposite directions require at least 1.4 seconds of candidate persistence, two observations and a 1.8-second previous-message dwell. Other changes use a shorter candidate dwell. Real zoom, loss and edge-safety states remain immediate. Manual subjects remain selected by the existing tracker and manual pinch/lens changes disarm automatic zoom until rearmed.

## 7. Tests and real results

37 new XCTest functions: three frozen-baseline failure assertions, 25 acceptance/assessment/memory/image cases, and nine evaluation/JSON/metric tests. Total: **294 registered XCTest functions**. Synthetic cases cover all ten requested acceptance scenarios, including the contained/clipped/small cat, well-composed person, scene-only landscape, multiple subjects, motion, manual selection, pinch cancellation and no improvement. One native integration case loads the existing real Unsplash landscape, runs the shared analyzer and checks that no object box is fabricated or file modified.

The real landscape starter annotation is included with provenance. It remains unconfirmed in the lab until the user saves labels. **No labeled real cat corpus has been supplied.** Real cat accuracy is not established by synthetic rectangles or this single landscape image.

Executed here: lexical delimiter checks across 96 Swift files; registration of 75 app/21 test sources; deterministic generation; resources/plists/shared scheme; JPEG/font/JSON resource integrity; YAML/shell syntax for normal and developer workflows; whitespace checks; frozen source integrity. These are **not** Swift grammar/type checks or native XCTest executions.

Native simulator test and device/evaluation build were attempted; both fail to start with `xcodebuild: command not found` in this Linux environment. **Zero native tests or hardware benchmarks were executed here.** Actual accuracy, recommendation improvement, inference time, thermal behavior, aesthetics results and old/new dataset comparison remain unmeasured. [Baseline status](BASELINE-STATUS.json) uses null values instead of fabricated performance numbers.

## 8. Remaining limitations

Apple's classifiers do not identify every conceivable item. Saliency boundaries can miss low-contrast subjects or represent only visible portions. True gaze, hidden anatomy, calibrated depth/perspective, semantic artistic value and optical-sharpness certainty are not implemented. The geometry/intent thresholds are transparent heuristics that need calibration against the user's examples; no greatest-photo guarantee is made.

The paired evaluator shares native detector outputs and separately applies frozen/new subject scoring before baseline/updated guidance. Explicit manual input is shared. It tests decision changes, not a historical detector implementation or historical inference runtime. Detection agreement means whether the human main subject is among the proposed regions (IoU ≥0.5 when a reference box is supplied); it is not object-detection mAP. Selection agreement checks the chosen subject. For explicit manual inputs, reference-box overlap measures selection separately from recognition. Negative scene labels must explicitly say no object box is needed.

Sequence contradiction/stability rates require distinct frames with real relative timestamps. They replay each engine's memory, but still images do not supply live IMU, lens, autofocus or stream state. Error cases are logged and excluded from denominators. Empty or unlabeled sets report Not measured. Recommendations are compared by structured action, not exact prose. Human preference labels can disagree; review disagreements before changing algorithms.

Sony uses actual received frames and the same shared live analysis pipeline. Lens zoom remains on the Sony camera. The new analysis and existing stream/capture recovery still require A7 III hardware verification; no Sony feed or successful connectivity is fabricated.

## 9. Collecting and labeling examples

Build Codemagic **ios-evaluation** on latest main. It runs tests, then archives with `FOCAL_EVALUATION` so a private AltStore IPA includes the lab. Normal ios-sideload omits developer tooling from Release. Install over Focal, then open Menu → Camera Settings → Developer Intelligence Lab.

Import real photos using the system picker. Label main subject or explicit no-object case, intent, acceptable composition, issue and preferred action. Drag a reference box on the image. Use the separate manual-input drawing toggle only when evaluating a deliberate manual selection; reference labels are never fed to automatic selection. Save labels to include that example in evaluation. Test images are local 1024px JPEG derivatives; camera originals and the gallery are unchanged.

Start with 30–50 examples spanning cats on textured beds, partly clipped cats, small pets, intentional close portraits, objects/vehicles/architecture, scene-only landscapes and no-change cases. Include your real failures and good photos under comparable conditions. For stability, import distinct frames from a clip and give them the same sequence ID with their actual times. Do not clone one image into a fake sequence.

Run Evaluate labeled examples, inspect per-image old/new advice and export the self-contained JSON with images, labels, hashes, measurements and results. Up to 100 images are allowed per dataset; use several sets for larger studies. Imports validate version, file names, box ranges, size limits and image hashes. Image I/O and expensive analysis are bounded; evaluation can be cancelled between operations. Explicit export is the only sharing path.

No training is justified yet. If held-out labels show detector/category misses dominate, consider a small independently licensed Core ML detector trained with Create ML or a supported conversion pipeline. A realistic first study would use roughly 1,000–3,000 diverse annotated photos, multiple scenes/devices/light conditions and subject boxes/categories, with 20–30% held out by capture session rather than random near-duplicate frames. Evaluate per-category detection/selection, action agreement and latency/heat on the phone before adopting a model. If detections are correct but actions disagree, improve/calibrate decision rules instead of enlarging the detector. This is a future proposal, not completed training.

## 10. Verify on iPhone 16 Pro Max

1. Run the new native tests and unsigned archive in Codemagic; install its IPA over the existing app through AltStore.
2. Compare good, clipped and small cats in Pet and Auto intent. Good framing must not demand isolation or a generic pose change; only actual frame-edge issues should request room.
3. Test off-center portraits, contextual groups and landscapes. A no-change frame should become Ready to shoot without a direction line. Explicit Center/Thirds overrides should still guide to their selected mark.
4. Enable AI/Tracking/Automatic Zoom/Composition Planning. Verify real crops retain edges/context, respect quality limits and cancel immediately on pinch or lens selection. Rearm guidance explicitly after manual zoom.
5. Move the phone and revisit a scene. Check hold/recovery and cooldown behavior; test manual tap ownership and AI off with normal AF.
6. Run the labeled corpus and share its JSON for evidence-based calibration. Confirm null/Not measured metrics become real counts only after actual evaluation.
7. Verify AUTO/PRO, repeated lens switching, RAW/HEIF/JPEG capture, gallery/Insights/Compare, preview cadence/temperature and actual Sony live view/shutter/recovery. No physical success is claimed by this source update.
