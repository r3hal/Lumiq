# Experimental Cloud AI Composition Scan

Status: isolated prototype on codex/focal-cloud-composition-scan, based on Phase 1 ef72620b3a4d6876202a936cae6508999f072fea. Main and the Phase 1 branch are not modified. No Framed source or IPA-derived implementation is used. Google Drive synchronization is not changed.

## Baseline audit

The complete 207-file Phase 1 snapshot matched the pinned remote Git blob hashes before edits. No existing Git working tree was present in the task snapshot; previous downloads and deliverables were left untouched. Source work is isolated in outputs/focal-cloud-scan. This Windows shell cannot start under the configured sandbox, so repository APIs create commits and Linux/macOS CI runs validation.

The user's physical iPhone report of repeated Finding your shot / Framing your shot / Aim your phone is accepted as a current-build observation. No new recording or timestamped trace was supplied for this implementation. The source audit establishes possible transition paths, not the cause or frequency of the device behavior:

- CameraController.processFrame updates scene evidence periodically and asks SceneCompositionPlanner / TargetRectangleSearch for local candidates outside an active/frozen shot. Existing freeze conditions cover active zoom, a pending tighter shot, and a verified completed shot.
- FramingPlanner owns preparation, aim, local motor verification, timed recovery and current-frame confirmation. AutomaticGuidance can emit different wording for those phases without the selected plan actually changing. A stable plan ID is needed to distinguish replanning from ordinary transitions.
- SubjectTracker retains Vision identity; CameraController computes visible-preview geometry. SubjectAutofocus uses that identity independently of Auto Zoom and preserves manual focus priority.
- Phase 1 freshness, retention tolerance, manual Thirds completion, result-ticket publication, manual zoom grace and user-only shutter paths remain in place.

Cloud AI is not claimed to fix the existing local-only loop. The experimental lock removes competing-candidate selection only while a verified cloud plan is active. Device traces must still distinguish plan changes, motion/quality gates, tracking loss and motor recovery.

## Architecture and ownership

An explicit UI action requests one fresh preview still. The camera serial queues provide that frame and local evidence; network work awaits an asynchronous CloudCompositionService outside the capture/analysis loops. GeminiCloudCompositionService implements the protocol using bounded, ephemeral HTTPS requests. Unit tests inject a transport; automated GitHub CI uses fixture credentials and sends no images. The explicitly started personal Codemagic workflow performs a real text-only model check.

The strict structured result passes JSON, enum, coordinate, text, confidence, zoom-budget, scanned-box, track-identity, freshness and scene-context validation. Only then does the analysis queue install CloudCompositionLock and invalidate earlier frame/AF tickets and READY proof. Acceptance does not advance or invalidate the camera/cloud session: a newer scan can start just after the old request is claimed, and its request must survive old cleanup. Publications keep the captured session snapshot. The lock holds a stable plan ID, target and technique. Local camera observations own arrows, framing safety, autofocus, hold duration, READY and recovery. Cloud types have no READY or capture capability.

A cloud zoom range is advice, not a motor command or measured benefit. Only an independently scored local candidate for the same technique/target, within that range and validated by the existing protected-crop/shot geometry, can enter the existing motor pipeline. Cloud confidence is never used as a local improvement score. If no such candidate exists, guidance uses the tracked target without a cloud motor plan. Manual zoom retains the composition, preserves the existing interaction grace and suppresses further cloud-plan motor changes until an explicit rescan.

While a lock is active, competing local composition searches are bypassed. Subject loss or expired wide-scene pixel evidence has a bounded 1.5-second recovery with no directional arrows or accumulated READY proof; prolonged loss/staleness, changed source/mode, an impossible context, a major measured scene change, explicit user selection/rescan, or a five-minute lifetime limit ends the lock and returns control to local planning. Fresh local evidence can keep a valid lock usable offline; it cannot preserve an old READY hold through a frame gap.

Every scan has an opaque request ID and camera-session revision. Old responses, cancellations and completions cannot clear or install over a newer request. Dismissal/cancel and superseding camera-context changes propagate Task cancellation into URLSession. Cancellation callbacks run outside the request-gate lock. A late callback registration cancels immediately, while an old completion cannot cancel a newer scan. Context/revision validation independently rejects obsolete results even if a transport ignores cancellation. The chosen Vision subject is retained through the cloud lock even when Auto Zoom and subject autofocus are both inactive.

## Photographic limits

All eight techniques are represented: Rule of Thirds, Centered, Leading Lines, Symmetry, Negative Space, Depth / Foreground Framing, Landscape Layers and Forest Path / Natural Framing.

A subject-based suggestion must match the currently selected local Vision track and its scanned box; its description must exactly match the supplied local label. This is deliberately conservative. It does not establish semantic accuracy beyond the local detector, nor prove aesthetic quality.

Without a reliable object track, accepted landscape/forest/architecture advice retains the wide current view at full-frame center. It does not claim that a model-described path, foreground frame or line is locally detected. Unsupported directional targets are rejected. A new attractive foreground candidate does not replace a locked wide composition. Any wide-scene READY still requires local pixel, motion, exposure and dwell checks. Roll suggestions require supporting local geometry and never directly change leveling or camera controls.

## Access and developer setup

Windows + Codemagic + AltStore personal testing now has a separate [private Debug workflow](PERSONAL_CLOUD_SCAN_WINDOWS.md). It accepts the key only as an encrypted Codemagic environment variable, verifies the real project model, and uses temporary SSH delivery without persistent artifacts. Automated GitHub CI continues to use fixture credentials only.

1. Use a local Debug build on a Mac with Xcode. Enable local AI Guide, use the iPhone source and Automatic composition mode. Manual Thirds remains a separate local flow. Sony Cloud Scan is intentionally disabled in this prototype.
2. Copy DeveloperExamples/CloudComposition.example.json to LocalDeveloper/CloudComposition.local.json at the repository root. Edit that local file with your own developer API key and chosen model. Do not paste keys into chat, Git, reports or public CI variables/artifacts. The separate personal Codemagic workflow is the approved encrypted-variable route; it generates this ignored file only during its private build.
3. The optional build phase copies the local file only into Debug app bundles. The directory and actual filename are Git-ignored. Release archives remove the configuration and the default service factory is disabled outside DEBUG. Automated GitHub CI has no real key and checks the unsigned Release archive for absence of the file. The optional personal Codemagic Debug workflow uses an encrypted variable and temporary private delivery as documented separately.
4. Long-press the AI Guide button and choose Cloud AI Scan (Experimental). Read the disclosure, acknowledge first use, and press Send one frame to Google. Opening the sheet does not transmit an image. Cancel/Done never takes a photo.
5. After acceptance, return to the viewfinder for local guidance. Use local composition guidance, select a subject/technique, or request an explicit rescan to unlock.

A Debug app containing the developer file exposes that key to anyone who obtains the bundle or controls the device. Git exclusion and Debug-only copying do not make an embedded secret secure. Never publish, share or attach a key-bearing Debug build or upload it to analysis services. The personal Codemagic route transfers it privately to your own computer/phone only. Do not add the real file or key-bearing IPA to retained CI artifacts. A distributed build needs the authenticated backend described in CLOUD_COMPOSITION_PROXY.md; the current Release prototype has no embedded developer credential or deployed backend.

## Exact configured model and API verification

Verified on 2026-10-17: the example configuration names gemini-3.8-flash. Google documents image input and structured output for this stable model, and lists a free tier. These are documentation checks, not a live authenticated inference test. No real developer credential was supplied or used in this task. Availability, project eligibility and quota must be checked for the developer's Google project; do not assume a free-tier listing makes a billing-enabled project free of charge.

The model identifier is configuration data, not a silent fallback. Before the first image request in a service instance, models.get must report the configured resource and generateContent capability. A missing/unavailable model produces a local fallback without an image POST. Future configuration changes must recheck image/structured-output support and pricing; capability metadata alone does not establish those properties.

The REST request uses inline JPEG data and generationConfig.responseFormat.text with a JSON schema, following the current API documentation. No tools, grounding, streaming, Files API or automatic retries are enabled. The response must finish with STOP and contain exactly one non-thinking text result. Malformed/truncated/unsafe results are rejected, not repaired into a plan.

Sources: [model capabilities](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash), [pricing](https://ai.google.dev/gemini-api/docs/pricing), [structured output](https://ai.google.dev/gemini-api/docs/generate-content/structured-output), [REST generation configuration](https://ai.google.dev/api/generate-content), [model metadata](https://ai.google.dev/api/models), [key security](https://ai.google.dev/gemini-api/docs/api-key).

## Requests, latency and privacy

One explicit scan uses one generateContent request. The first scan per new service/sheet instance also makes one model-metadata GET; subsequent scans in that instance reuse it. There are zero Gemini calls while guiding a locked composition and no automatic retries after quota/timeout/invalid results. A failure before generation can send no image at all. Cancellation cannot retract a request Google has already received.

The encoder crops to the visible preview, honors the already upright capture connection and front-camera mirroring, limits the long edge to 768 pixels, and re-encodes at JPEG quality 0.65. It reduces resolution further if necessary to stay within 160 KiB. Source metadata is not copied, and no upload image is written to disk or retained by the controller. Saved-photo originals, gallery and editor data are not used as inputs.

Requests use a 20-second request timeout and 25-second resource timeout, no cache/cookies, no redirects, bounded response bytes and cancellation. Model metadata plus generation can span two such requests; the local matching window rejects old scan contexts. Network work does not stop live capture or local guidance. Errors are fixed user-facing enums; upstream error bodies, credentials and free-form cloud explanations are not written to camera diagnostics.

Google's treatment of submitted data depends on account, service and region. Unpaid-service terms can permit product improvement and human review; EEA/Switzerland/UK provisions differ. Google may retain data under its applicable terms. Focal does not promise that Google retains nothing. The first-use disclosure points to those terms. The experimental privacy manifest conservatively declares submitted photo/video content, linked data, App Functionality purpose and no tracking. Review the actual production data flow before distribution. [Google data terms](https://ai.google.dev/gemini-api/terms), [Apple privacy manifest types](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype).

## Changed files

| File | Change |
| --- | --- |
| `.github/workflows/cloud-composition-validation.yml` | Dedicated Linux/macOS branch CI, pinned Phase 1 portable baseline, native tests and unsigned Release archive without developer configuration. |
| `.gitignore` | Excludes the local developer directory and real credential filename. |
| `DeveloperExamples/CloudComposition.example.json` | Placeholder-only configurable model/key example; contains no usable secret. |
| `Focal.xcodeproj/project.pbxproj` | Registers cloud sources/tests and optional Debug configuration copy phase. |
| `Focal/Camera/CameraController.swift` | One-frame capture handoff, request/context cancellation, conservative matching and local locked-plan integration; preserves local READY, motor and AF ownership. |
| `Focal/Camera/CameraView.swift` | Explicit experimental Guide context-menu entry and scan sheet; preserves camera continuity while presenting it. |
| `Focal/Cloud/CloudComposition.swift` | Protocol, strict result types/validation, local evidence matcher, request gate and bounded composition lock. |
| `Focal/Cloud/CloudCompositionScanView.swift` | First-use Google disclosure, explicit Send/Cancel actions and safe scan status. |
| `Focal/Cloud/CloudFrameEncoder.swift` | Visible-preview crop, orientation/mirroring and bounded metadata-free pixel re-encoding. |
| `Focal/Cloud/GeminiCloudCompositionService.swift` | Configurable model verification, schema-based Gemini adapter and cancellable bounded ephemeral HTTPS transport. |
| `Focal/Resources/Info.plist` | Camera usage description explains explicit one-frame cloud processing. |
| `Focal/Resources/PrivacyInfo.xcprivacy` | Conservative optional photo/video data declaration for the experiment. |
| `FocalTests/CloudCompositionTests.swift` | 34 policy/transport tests covering validation, failure, subject matching, lock retention, manual zoom, local READY and stale/cancelled results. |
| `FocalTests/CloudFrameEncoderTests.swift` | Three native image tests for crop/size, private metadata removal, mirroring and no upscaling. |
| `scripts/generate_project.py` | Deterministic project/privacy generation including optional Debug configuration phase. |
| `scripts/test_framing_portable.py` | Runs unchanged cloud policy and transport sources in the portable XCTest harness. |
| `scripts/validate_structure.py` | Updates registered test count and adds credential, locked-tracking, integration and user-only shutter guards. |
| `docs/CLOUD_COMPOSITION_SCAN.md` | Baseline audit, architecture, setup, model verification, evidence, exact changes, validation, limitations and iPhone checklist. |
| `docs/CLOUD_COMPOSITION_PROXY.md` | Production authentication, quota, abuse protection, secret handling and retention architecture; not a deployed backend. |

## Validation

This section records the original experimental implementation. Current personal Codemagic build validation is recorded in [PERSONAL_CLOUD_SCAN_WINDOWS.md](PERSONAL_CLOUD_SCAN_WINDOWS.md).

The new suite adds 34 portable policy/transport tests and three native image-encoding tests. The portable and native totals overlap; they are not distinct additional suites to sum together.

| Area | Coverage |
| --- | --- |
| Structured response | Valid schema and all eight techniques; malformed JSON/markdown; unknown or extra fields (including READY/capture); finite values, text, boxes, coordinates, confidence, alternatives and roll bounds. |
| Live matching | Same Vision identity and label, overlapping scanned box, reliable tracking, valid preview target, device/detail zoom budget, user intent/mode, fresh scene evidence, source/session/zoom changes and old scans. |
| Lock and local guidance | Stable plan ID/target/technique; bounded loss and recovery, including stale wide-scene pixels despite fresh video observations; scene/source/lifetime expiry; manual zoom priority and motor grace; independently measured motor gain; cloud confidence cannot grant READY; fresh local offline continuation. |
| Async transport and fallback | One inline JPEG, schema and no tools/stream; model capability check/cache; quota/auth/model errors; timeout/no internet; cancellation while awaiting transport; new/old request completion and context-cancellation ordering. |
| Native image preparation | Correct visible aspect/size, upright output, front mirror exactly once, no upscaling, removal of injected GPS/private EXIF with only technical encoding tags allowed. |
| Integration/regression | Existing Phase 1 framing/READY/AF/zoom tests; Sony protocol suite; deterministic generated project; historical source hashes; locked tracker retention independent of motor/AF; explicit upload UI and user-only shutter source guards. |

Final code revision: `d75a2f768ed1ac72c26cd54cfad85757e27074aa`. [GitHub Actions run 39025252475](https://github.com/r3hal/focal-private/actions/runs/39025252475) completed successfully on 2026-10-17. The delivery commit adds only these two documentation files after that tested revision.

| Check | Environment | Result |
| --- | --- | --- |
| Untouched Phase 1 baseline | Ubuntu 24.04, Swift 6.4; detached worktree at ef72620 | 358 framing tests + 75 Sony tests, zero failures. |
| Current portable production policies/transport | Ubuntu 24.04, Swift 6.4 | 392 framing/cloud tests, zero failures; includes all 34 new cloud tests. |
| Current Sony protocol suite | Ubuntu 24.04, Swift 6.4 | 75 tests, zero failures. |
| Structure and source guards | Linux, Python | Passed: deterministic project regeneration; 103 app/38 test Swift references; 674 registered native test methods; JSON/plist/XML/assets/YAML/shell syntax; historical source hashes; locked-tracker, stale-result, manual-zoom and user-only shutter integration guards. |
| Swift parsing | macOS 15, Xcode 16.4 (16F6) | All app/test Swift sources passed `swiftc -frontend -parse`. |
| Native XCTest | macOS 15, Xcode 16.4; iPhone 16 Pro simulator, iOS 18.5 | 674 tests, zero failures; both new cloud suites passed, including the three native encoder tests. |
| Unsigned iPhone archive | Xcode 16.4, Release, generic iOS destination | Archive step succeeded with signing disabled; the following absence check for `Focal.app/CloudComposition.local.json` passed. This is not a signed or installed device build. |
| Local source integrity | Node filesystem/hash inspection on Windows | All 215 tracked code/config files matched the tested Git blob hashes; 198 existing Phase 1 files remain byte-identical. No real developer configuration exists in this snapshot; changed files contain no Google API key pattern. |
| Live Gemini and physical camera | Not executed | No real key or camera frame was supplied to Google. No physical iPhone or Sony hardware test was performed in this task. |

Portable commands: `python3 scripts/test_framing_portable.py`, `python3 scripts/test_sony_portable.py`, and `python3 scripts/validate_structure.py`. The workflow records the exact native commands, resolves an available simulator UDID, runs `xcodebuild ... test`, then `xcodebuild ... -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive` and checks credential-file exclusion. [Portable job](https://github.com/r3hal/focal-private/actions/runs/39025252475/job/117374932663), [native test/archive job](https://github.com/r3hal/focal-private/actions/runs/39025252475/job/117374932497).

Initial validation caught a Linux CGFloat-to-JSON bridging issue, corrected by explicitly encoding box values as Double. Two test fixtures were corrected to use distinct evidence timestamps and to distinguish private EXIF from JPEG pixel-dimension tags; the metadata test now injects private source fields and verifies their removal.

The build succeeds in the repository's Swift 5 language mode. Xcode reports two new non-Sendable CameraController capture warnings at the queue/continuation boundaries. Queue ownership and request guards are explicit, but this is not a claim of strict Swift 6 concurrency checking or Thread Sanitizer coverage. Those remain follow-up validation work; no unchecked Sendable conformance was added to the camera controller.

Windows cannot execute Xcode/UIKit/AVFoundation tests or build an iOS archive. Native checks run on macOS CI; portable policy/transport tests run on Linux. Mocked API tests do not establish actual Gemini response quality, account access, quota eligibility or physical camera behavior.

## iPhone verification scenarios

- [ ] With no configuration/offline, local Guide, manual Thirds/Center, autofocus and deliberate capture still work. Opening Cloud Scan sends nothing.
- [ ] First-use disclosure is required; only pressing Send submits one JPEG. Verify traffic: one image POST and, for a new service instance, one metadata GET. No repeated calls while guiding.
- [ ] Back/front cameras and all aspect ratios: verify displayed JPEG crop/orientation/mirroring matches the local boxes. Confirm no GPS, capture timestamp, device identifiers or original-photo metadata are sent.
- [ ] A reliable person/pet/product scan locks one target and technique. Pan slowly and introduce other attractive subjects; the plan ID stays fixed. Observe local arrows and fresh READY hold.
- [ ] A forest/path/landscape scan with no local track gives wide framing advice without invented object boxes/pan arrows or cloud-driven zoom. Verify local READY is earned independently.
- [ ] Move the selected subject out of view: arrows disappear during recovery and READY proof stops; reacquisition within grace retains the composition; prolonged loss returns to local guidance. For a wide lock, force rapid movement/expired pixel analysis; it must recheck the scene without falling through to a new object arrow.
- [ ] Change scene, camera source, composition mode, lens/aspect, Guide state or selected subject while a response is delayed. The old response must not apply. Dismiss/reopen/rescan rapidly to exercise old-cancellation/new-request ordering.
- [ ] Pinch/slider/lens stops with a locked plan preserve Guide and target, keep manual focus/control values and respect motor grace. Cloud-plan motor changes remain suppressed until rescan. Repeat Auto Zoom OFF and ON.
- [ ] If a local candidate admits zoom, verify crop/anatomy safety, actual stopped motor, fresh alignment and hold before READY. A high cloud confidence alone must never show READY. Wait through READY without touching the shutter: no photo may be taken automatically.
- [ ] Simulate quota, timeout, no internet, malformed JSON and blocked/truncated response. The scan ends, the camera remains responsive, settings/photos remain intact, and no retry loop begins.
- [ ] Disconnect internet after a successful lock. Fresh local tracking can continue; stale frames revoke READY and invalid scene context/lifetime ends the lock without another upload.
- [ ] Reproduce the Phase 1 transition sequence with the scan disabled and then with a valid lock. Export a timestamped local trace (without images/keys/model prose), compare stable plan IDs, tracking identity, measured motion, crop gates, actual zoom and READY age. Do not judge replanning from wording alone.
- [ ] Run for five minutes on the oldest supported iPhone; measure preview cadence, guidance latency, heat and memory. Cover background/foreground and interruptions.
- [ ] Sony A7 III: connect/reconnect, Live View, iPhone/Sony source switching, external controls and deliberate capture. Cloud Scan remains unavailable for Sony. Verify gallery, editor, film effects, RAW and paired-save behavior. No Google Drive upload is added.

## Remaining risks

The cloud adapter and strict matching may reject useful suggestions. Similar-looking scene changes can evade the existing coarse photometric guard; exposure changes or large intentional pans can invalidate a lock. Model semantics and aesthetic benefit are not calibrated by unit fixtures. A successful mocked request is not a live Gemini integration test. Actual network latency, buffer alignment, focus hunting and motor timing require device verification. The earlier local-only transition loop remains an independent issue; this branch does not claim to solve every cause.
