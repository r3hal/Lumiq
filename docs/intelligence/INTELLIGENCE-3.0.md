# Focal Intelligence 3.0 — Focal 2.3 / build 20

This is an incremental guidance-engine change. The camera layout, photo/RAW pipeline, manual controls, gallery and Sony connectivity are preserved. Only the existing guidance card's empty-message behavior changes in production UI. Developer evaluation gains labels and result rows.

## 1. Why guidance was poor

The older 2.1 audit remains in AUDIT.md. Intelligence 2.0 already removed generic isolation/eye-level advice and large-contained-box “Step back” rules, compared against the current frame, and added recommendation memory. Inspection of the actual 2.2 code found remaining failures:

- Crop/room recommendations were not classified as opposites; room advice bypassed cooldowns.
- Edge correction ran before motion checks, potentially advising movement from an unsettled box.
- Bounds and pixel evidence were stamped at evaluation time after inference, concealing observation age.
- Head/pose accessors renewed their timestamps when read.
- Horizontal placement scoring could penalize deliberate peripheral portraits; explicit portrait/pet relevance still rewarded centering.
- Candidate ranking favored maximum gain rather than the smallest useful crop. Target-placement gain was estimated from the original penalty without checking the proposed geometry.
- Recommendation worsening was compared with the immediately preceding frame, missing cumulative deterioration.
- Zoom dwell checked gyro stability without requiring a fresh observed subject velocity.
- Weak observations still displayed an instruction. No-object scenes bypassed recommendation memory.

Seven initial regression cases were written before editing these decision rules. They encode failures found by source inspection, not physical-device reproductions. Native executions were unavailable.

## 2. Algorithms fixed

`GuidanceSceneSnapshot` joins measured preview geometry, confidence, context, exposure, intent, anatomy, observation time and relative movement without retaining image buffers. The live decision engine consumes this representation. Conservative confidence smoothing can delay trust but never raise a weak raw confidence. A face label now resolves to the face category.

Phone frames carry admission time into the serial analysis queue. Work older than 900 ms is rejected before inference or before publication/automatic focus/zoom. Sony's age begins when its decoded image reaches the existing analysis pipeline; this does **not** measure Wi-Fi transport latency. Stale outputs withdraw the old box and instruction. Evidence retains image observation time, and anatomy retains detection time. A slow device may consequently show less guidance; the 900 ms policy requires calibration on hardware.

Motion is checked before edge advice. Abrupt same-label jumps over 0.55 normalized frame units reset memory; this is a conservative scene-replacement heuristic, not a re-identification model. Already-good frames remain acceptable.

## 3. Models actually used and broader detector investigation

No new trained model, remote AI service or proprietary Framed implementation was added. Existing native requests remain: human/face rectangles, animal recognition, objectness/attention saliency, region/scene classification, rectangles, text, object tracking, and throttled animal/human poses. Apple image aesthetics remains optional for stored images/evaluation and never invents directions.

Native specialized pet recognition/pose targets cats and dogs. Other animals, food, flowers, vehicles and products can become named candidates only when the installed Apple classifier actually recognizes their observed region and relevance gates accept it. Saliency is a proposal, not semantic object detection. Classifier labels are not proof of correct localization. This does not claim every noun or every animal is recognized.

Primary-source investigation: [Apple's model catalog](https://developer.apple.com/machine-learning/models/), [Apple's YOLOv3 package/model card](https://huggingface.co/apple/coreml-YOLOv3), [Vision classifier vocabulary API](https://developer.apple.com/documentation/vision/vnclassifyimagerequest), [Ultralytics Core ML export](https://docs.ultralytics.com/integrations/coreml), and [Ultralytics licensing](https://www.ultralytics.com/license). Apple's YOLOv3 package is a broad object detector with a MIT-labeled model card; it is much larger than the existing built-in pipeline. Ultralytics models offer Core ML deployment with AGPL/enterprise terms. Neither has been benchmarked on this app's iPhone 16 Pro Max, nor has its exact artifact/category metadata been validated locally. Neither is shipped or claimed supported. Adding an unverified model would violate the requested compatibility/performance gate. Broader localized detection remains a physical-device/model-validation follow-up.

## 4. Subject relevance

Relevance retains actual detector confidence (0.35), category priority (0.12), classification confidence (0.15), visual prominence (0.12), image separation (0.08), size (0.07), placement (0.11), measured composition potential (up to 0.10) and bounded texture/peripheral penalties. These are transparent heuristic weights, not a learned probability or calibrated accuracy estimate.

Explicit portrait/pet intent removes the horizontal centering preference and the Auto-only small-peripheral semantic penalty. Category gating means a portrait does not select furniture and a pet portrait prioritizes recognized cats/dogs. Auto still permits a prominent named foreground object to outrank an irrelevant background person. Anonymous/background regions remain rejected. Existing acquisition dwell, switch margin/dwell, spatial identity association, loss recovery and manual tap priority remain.

## 5. Composition assessment

Measurements remain visibility, frame margins, observed headroom/joints, intent-specific area/placement, nearby named regions, color/edge separation, visual mass, candidate boundaries/vertical lines, actual exposure and observed motion. Anatomy applies only to semantic human/pet candidates and must be fresh. Missing joints are not evidence of clipped limbs. Head yaw is not eye gaze; no gaze-direction improvement is claimed.

Comfortable off-center portraits/pets incur no horizontal recentering penalty. This preserves deliberate negative space without guessing intention. Products retain their own region/size ranges. Architecture can receive whole-scene advice without a fake box: multiple coherent long verticals support an optional alignment check, never a mandatory perspective correction. Landscape still uses actual scene pixels/roll rather than an invented object. Texture alone does not establish a distraction. Optical blur, depth/separation and intentional perspective are not fully inferred.

## 6. Recommendation selection

Keep-current is always compared with crops inside the observed frame. Subject, relevant context and enclosing frames must survive a crop; margins are checked again before a real ramp. Candidate target shifts now measure the resulting subject placement/visibility rather than awarding every target the same estimated gain. A target shift does not claim knowledge of newly revealed surroundings.

A useful crop must exceed 0.08 measured improvement after crop/quality cost. The smallest qualifying crop takes priority, including a verified least-change candidate even when a technique's heuristic prefers a larger crop. Hardware/detail limits still restrict available live scales. There is no wider-preview simulation: an edge correction can suggest giving visible edges room, but cannot predict unseen scenery.

Motion/loss/weak confidence suppress movement. Acceptable framing produces “Ready to shoot” after existing settling requirements, or silence. Generic isolation and lower-viewpoint instructions are not generated by the live decision pipeline.

## 7. Temporal memory and contradictions

The original acquisition/lock/loss mechanisms remain. Recommendation memory now tracks issue change against the measurement at the start of an instruction; two changed observations showing cumulative worsening withdraw advice and reassess. Alignment/no-longer-needed decisions withdraw previous commands immediately. Crop versus room reversal uses persistence/cooldown and shows a neutral hold instead of continuing an unsafe old crop command. Direction reversals retain the existing delay/dwell guards. Scene-only assessments now use the same memory.

Issue change is correlation, not proof that the user's movement caused it. Logs distinguish improvement, deterioration, no significant change and withdrawal. This is not a learned motion predictor.

## 8. Automatic zoom

Existing AI toggle, automatic-zoom setting, manual pinch/zoom cancellation, generation guards, lens/detail limits and one-ramp-per-scan rule remain. Zoom now additionally requires a fresh, measured slow subject (normalized speed ≤0.12/s), a stable camera and a meaningful measured tighter crop. The first observation cannot start a ramp because no velocity exists yet. Motion or low tracking confidence during a ramp cancels it. Manual controls are not rewritten. Hardware ramp completion stops at the evaluated target; no repeated oscillating rescans are introduced.

A digital crop cannot reveal content outside the live view. It does not make Sony's Wi-Fi JPEG optical quality better, and no Sony zoom/connectivity command was added.

## 9. Tests and build results

**No XCTest or Xcode build passed in this Linux workspace.** Both simulator test and Release evaluation build were attempted; `xcodebuild` is unavailable (exit 127). There are 314 registered XCTest functions, including 20 added in this update. Project/resource generation, data formats, configured shell scripts and whitespace can be checked here; those checks do not type-check Swift.

All 12 requested scenarios have deterministic coverage: contained cat/clutter; observed edge/head clipping; small cat with measurable crop; already-good person; intentional peripheral portrait; no-object landscape; retained multi-subject selection; response/outcome memory; steady acceptable composition; manual zoom disarming; fast movement suppressing commands; insufficient-confidence silence. New tests additionally cover stale observations, weakest-confidence bounds, same-class replacement, smallest useful crop, cumulative deterioration, no anatomy on products, scene readiness clearing old advice, and export compatibility/crop-label metrics. These are registered cases, not a report of execution or recognition accuracy. Real ears/paws recognition and capture/motion scenarios still require photos and hardware.

Codemagic workflows continue to run native tests before the unsigned IPA archive. Use `ios-sideload` for normal installation; use `ios-evaluation` for developer diagnostics and the labeling/evaluation tool. Tests are not skipped.

## 10. Measured improvements and human evaluation

**Accuracy, latency, harmful-guidance reduction and actual zoom/tracking improvements are unmeasured.** Before/after values remain null. The local evaluation tool now compares frozen Focal 2.2/build 19 decisions against Intelligence 3.0 on the same current detector outputs. Baseline source hashes are in BASELINE-22-SOURCES.json. The older 2.1 baseline is retained for source audit but is not the primary comparison now.

The tool records human labels for acceptable/intentional composition and automatic-crop appropriateness, calibration versus held-out split, ground-truth boxes separate from manual input, optional timestamped sequences, and feedback notes. It exports paired measurements/results locally. Existing JSON remains readable. Held-out recommendation metrics are reported separately. Added unwanted-crop metrics evaluate **static crop proposals**, not executed ramps. Added consecutive box overlap is a continuity diagnostic, not ground-truth tracking accuracy. Historical detector latency is not fabricated.

`EVALUATION-PROTOCOL.json` specifies real-photo category coverage and the 12 scenarios. It is a collection protocol, not a finished labeled corpus. The only included real starter remains the existing landscape, unconfirmed until reviewed. No labeled real cat/portrait/product corpus was available. Import your own images into the developer lab, annotate and keep capture sessions separated between calibration and held-out sets. Require no-adjustment examples and human review of misleading advice. No photos are uploaded or trained on automatically.

## 11. Remaining limitations

This is native Vision plus measured heuristics, not a commercial semantic/aesthetic foundation model. It cannot reliably recognize all objects, infer arbitrary photographer intention, eye gaze or unseen camera viewpoints, measure optical sharpness from a single low-resolution analysis sample, or guarantee the greatest composition. Correct localization and class coverage remain the main detection limitations. Benchmark claims require a reviewed real corpus; current-image paired evaluation shares detections and does not recreate historical detector behavior.

Developer diagnostics are local, private OSLog events throttled to one per second. They include selected subject/confidence/intent, measurements, candidate gain/scale/rejection reasons, prior/current action, memory outcome, framing phase and observation processing age. Age includes queue/processing; it is not a profiled per-model inference duration. Normal Release excludes these logs and evaluation components. No photos, pixel buffers, filenames or network telemetry are logged.

## 12. Required physical-device verification

First obtain a successful Codemagic native test/build. Install build 20 with AltStore. On iPhone 16 Pro Max, verify fresh meaningful people/pets/products/nature/architecture, no forced box on empty scenes, preserved negative space, clipped versus comfortably contained cats, contextual multi-subject retention, hold duration, rejected stale results, manual pinches canceling ramps immediately, safe lowest-useful crops and no oscillation. Measure actual admitted-frame latency, rejected-frame proportion, live cadence, thermal/battery behavior and real recognition errors over extended sessions. Verify manual controls, RAW/photo resolution, gallery and AI OFF regressions.

For Sony A7 III, verify the unchanged real connection, JPEG live view and capture, shared guidance decisions, loss/recovery and UI responsiveness. Analysis age cannot detect a frame already stale inside camera transport. No claim is made that Sony latency/quality or A6100 compatibility has been improved by this guidance-only update.
