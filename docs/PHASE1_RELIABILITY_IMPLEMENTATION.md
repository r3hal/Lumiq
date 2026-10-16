# Focal Phase 1 reliability implementation

Scope: the user-approved Phase 1 only. No Phase 2 work, Framed source reuse, IPA-derived implementation, or automatic shutter release.

## Baseline and isolation

- Baseline: main at 61081f524fb6e10d66bfb24d0e8c30953a4a9b4f (2.11.1, build 38).
- No existing Git checkout was found in the supplied task/download locations. Existing downloads and analysis were left untouched. A complete, hash-checked source snapshot was created under outputs/focal-phase1.
- Dedicated remote branch: codex/focal-phase1-reliability. All implementation commits are on that branch. Main was not updated by this task.
- The local shell could not start under this Windows sandbox. GitHub repository APIs were used for branch creation and commits; validation runs on Linux and macOS GitHub Actions.
- The baseline had a successful Codemagic simulator test and unsigned archive run: https://codemagic.io/app/6acd1c013f91ff6b0afba48f/build/6ad1d1457550aed8108f2f97. The new CI independently reran the unmodified baseline portable suites: 330 framing tests and 75 Sony tests passed.

## Behavior changes

1. READY acquisition requires consecutive fresh, eligible observations. A gap over 0.9 seconds, changed subject/session identity, backwards/duplicate time, or invalid input resets the hold. A final zoom verification hold also cannot span a stale gap.
2. READY retention uses a slightly wider, bounded position/roll/assessment tolerance. Minor geometric changes do not restart a completed hold. Lost subjects, unsafe edges, weak evidence, significant movement and expired observations revoke READY. This is not an absolute timeout for a good scene: fresh qualifying evidence can keep READY active.
3. Wide-scene completion also compares an 8 × 8 RGB signature with its acquisition anchor. A mean absolute channel change over 0.18, a changed broad scene category, or a changed composition technique revokes the inherited hold. The anchor comparison catches accumulated drift across several smaller changes. This reuses the existing sampled grid without extra inference. It is a photometric reset, not semantic scene recognition.
4. Every published result has a revision, sequence and observation time. Context changes invalidate outstanding work before configuration is enqueued; publication rechecks the ticket on the main queue. Old frame results and old expiry callbacks cannot clear a newer displayed result. A timer clears stale displayed guidance even when frames stop arriving or a newer analysis is still running. Delayed cleanup invalidates capture verification only if its evidence is actually stale.
5. Manual Thirds and Center have measured completion independent of Auto Zoom permission and a zoom plan. Manual Thirds/disabled Auto Zoom do not enter motor preparation. Thirds target locking survives manual zoom replanning. Manual zoom keeps AI Guide enabled, invalidates obsolete geometry, and retains the existing motor grace/subject tracking.
6. Subject identity changes clear READY, alignment/message history and cached subject measurements/motion. A same-label replacement cannot inherit completion from the previous subject.
7. Subject AF eligibility follows AI Guide and subject tracking, independently of Auto Zoom. Manual focus stays authoritative. Existing point smoothing, 0.2-second minimum retarget interval, movement deadband, continuous AF mode, loss grace, hardware checks and retry limits are retained. Physical focus behavior still needs device observation.

## Exact changed files

| File | Purpose |
| --- | --- |
| Focal/Camera/CameraController.swift | Revision/ticket admission and publication, expiry, manual motor gating, subject evidence reset, target retention, AF coordination. |
| Focal/Camera/SubjectAutofocus.swift | Pure focus eligibility policy independent of zoom. |
| Focal/Composition/GuidanceObservation.swift | Consecutive READY evidence, measured wide-scene change reset and thread-safe result/expiry gate. |
| Focal/Composition/CompositionEngine.swift | Entry/exit tolerance, stream-gap and missing-subject reset. |
| Focal/Composition/FramingPlanner.swift | Current-frame/manual dwell, expiry, final zoom continuity and recovery proof reset. |
| Focal/Composition/ShotReadiness.swift | Measured manual layout eligibility and bounded retention thresholds. |
| Focal/Composition/AutomaticGuidance.swift | Keep an actually verified, still-good current frame READY instead of replacing it with speculative advice. |
| FocalTests/ContinuousFramingRecoveryTests.swift | 28 new production-policy regression tests. |
| FocalTests/AutomaticShotFramingTests.swift | Intermediate observation in existing positive dwell fixture; original assertions retained. |
| FocalTests/FramingProgressionTests.swift | Intermediate observation in existing positive dwell fixture; original assertions retained. |
| FocalTests/SceneCompositionPlannerTests.swift | Intermediate observation in existing positive alignment fixture; original assertions retained. |
| scripts/validate_structure.py | Updated registered test count; select a historical baseline ref only when every recorded SHA-256 matches. |
| .github/workflows/phase1-validation.yml | Branch-scoped baseline/portable checks, native simulator tests and unsigned iPhone archive. |
| docs/PHASE1_RELIABILITY_IMPLEMENTATION.md | This implementation, validation, risk and device-verification record. |

## Validation

Tested source revision: d145c6d31cdec22eae0503b89ca1ca5f3e2150fd. The subsequent report commit changes documentation only. [GitHub Actions run](https://github.com/r3hal/focal-private/actions/runs/38939467995).

| Check | Result |
| --- | --- |
| Unmodified baseline portable suites | PASS: 330 framing + 75 Sony tests, zero failures. |
| Final production framing suite, Linux / Swift 6.4 | PASS: 358 tests, zero failures; includes all 28 new regression tests. |
| Final Sony portable suite | PASS: 75 tests, zero failures. |
| Structural validation | PASS: deterministic project generation, all 99 app / 36 test Swift references, JSON/plist/XML/assets, build-script syntax, historical source hashes and whitespace. 637 XCTest functions registered. |
| User-only shutter guards | PASS: capture UI unchanged, explicit user shutter action retained, no automatic readiness-to-shutter call. |
| Native parsing, Xcode 16.4 | PASS: all app and test Swift sources. |
| Native simulator XCTest suite | PASS: 637 tests, zero failures; **TEST SUCCEEDED**. |
| Unsigned Release iPhone archive | PASS: **ARCHIVE SUCCEEDED**, Xcode 16.4 / generic iOS destination, signing disabled. |
| Local snapshot integrity | PASS: all 206 tracked source/resource files reproduce committed tree 594d5f573bb6b2856e93633b33bc9e8563594bc4. |
| Physical iPhone and Sony A7 III | Not run; checklist below. |

No native build or test was executed on Windows. This Windows environment lacks Xcode and the sandbox shell could not start. Native simulator and archive checks use a macOS runner; live camera checks require a physical iPhone. The Linux portable harness compiles production policy sources with its documented platform substitutions, so its results are not a substitute for native or hardware validation.

The first CI run exposed an existing baseline-30 reference problem. The manifest's local snapshot commit lacks the recorded files; its published commit contains the exact expected SHA-256 values. Validation now accepts only a candidate matching every recorded hash. No baseline hash was weakened or rewritten.

An intermediate portable run passed its 24 new tests and found three old positive fixtures with a one-second observation gap. Intermediate samples were added to those fixtures without changing their expected outcomes. Negative stale-gap tests remain in place.

## Remaining risks and practical limits

- Pure policy fixtures and simulator execution do not establish live Vision tracking, real AVFoundation queue timing, camera buffer freshness, lens behavior or image quality. Main-queue delayed publication and expiry ordering are modeled with production gates; actual device scheduling needs a stress run.
- The existing 0.9-second guidance freshness limit is deliberately enforced. Sustained overload/thermal throttling may show reassessment instead of READY; it must not preserve old READY. Measure this on the oldest supported iPhone before release.
- The scene-change threshold is covered by controlled pixel fixtures, not a calibrated scene dataset. Similar-looking scenes may not cross it; exposure changes can cross it. Verify landscape pans and lighting changes on an iPhone. It does not claim semantic recognition of a new scene.
- AF uses existing supported continuous autofocus. Test real depth changes and lens changes for hunting, including Auto Zoom off and manual focus recovery.
- Sony, gallery, editor, effects, capture UI and project resources were compared against the pinned baseline and are unchanged. Shared camera-controller code is changed, so real camera and Sony smoke checks are still required.
- This phase does not redesign landscape/forest scoring, subject detection, automatic crop search or introduce new composition features.

## iPhone verification checklist

Record device/iOS/build, timestamps, selected mode/intent/Auto Zoom value, and exported debug framing trace where available. Record failures as observations, not inferred detector or motor behavior.

- [ ] Manual Thirds: with Auto Zoom OFF, select each of the four corners, acquire a reliable subject, align and hold. READY completes; zoom and selected corner stay unchanged. Repeat with Auto Zoom ON. Repeat Center.
- [ ] READY continuity: maintain a good portrait/object scene for at least 30 seconds with small handheld variations. READY does not repeatedly flicker or launch a new crop. Exceed position/roll/motion tolerance and confirm READY exits.
- [ ] Subject loss/recovery: move the selected subject out of view, cover/uncover the lens, then reacquire. READY clears; recovery needs fresh evidence. Switch between two people/pets of the same label and confirm no inherited completion.
- [ ] Expiry: in a debug build stop frame delivery while READY without stopping the UI/main queue. READY clears after the last observation's 0.9-second budget plus scheduling tolerance. Resume delivery and confirm a fresh hold is required. Also test background/foreground and interruption recovery.
- [ ] Zoom: pinch, use the zoom slider and lens stops while guidance is acquiring, aligning, READY and verifying an automatic ramp. AI Guide stays enabled; no old READY/crop returns; Thirds target and manual camera values are retained. The motor respects active touch and existing post-touch grace.
- [ ] Race stress: rapidly change subject, composition mode, camera source, aspect, intent, lens and Guide ON/OFF while analysis is busy. Old results/expiry do not overwrite the latest context.
- [ ] AF: with Auto Zoom OFF and tracking ON, move the subject sideways and in depth. Focus follows without unnecessary repeated point changes. Repeat with Auto Zoom ON; tap focus; Pro manual focus; tracking/Guide OFF; front/back cameras and lens changes.
- [ ] Automatic zoom: acquire, interrupt a ramp, lose/reacquire a subject, complete verification, then change the scene. Existing safe-crop/recovery behavior remains; READY expires; the shutter never fires automatically.
- [ ] Forest/landscape: hold a wide view, pan to a new scene and switch to a portrait. Verify sensible reassessment and no stale READY. Scoring quality is recorded for a separately approved phase.
- [ ] Five-minute run on the oldest supported iPhone: watch preview cadence, guidance latency, dropped updates, temperature and memory. Freshness failures produce reassessment and recover when performance improves.
- [ ] Sony A7 III: connect/reconnect, start/stop Live View, switch between Sony/iPhone, use exposed external-camera controls and trigger only deliberate user captures. Live View and controls remain responsive.
- [ ] Gallery/editor/film effects: save a deliberate iPhone and Sony capture, open gallery, edit, apply effects and export. Confirm photo/RAW/paired-save behavior and manual exposure/WB/zoom controls are unchanged.

Phase 1 stops here. Phase 2 requires separate approval.
