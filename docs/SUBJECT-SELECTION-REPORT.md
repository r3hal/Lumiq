# Focal 1.6 / build 8 — selective AI Guidance

Baseline: 34809d6; [audit before edits](SUBJECT-SELECTION-AUDIT.md).

## Controls and inference

Reuse the footer circular button: AI Guidance Off uses a dark circle/yellow outline, On uses the existing yellow accent. It keeps the accessible name AI Guidance and explicit On/Off values. A one-time migration starts older and fresh installs off; subsequent explicit choices persist. It is independent of flash/exposure/capture. No extra permanent button, navigation bar or grid is added.

Off skips Vision and coach analysis, including Sony analysis-frame decode. Active Vision requests receive cancellation, request-launch checks prevent late starts, and activation/source revisions reject late results from an earlier off/on/source state. The normal preview, native autofocus/tap focus, manual zoom, shutter and real telemetry remain active. The camera still receives its ordinary capture/preview buffers; Sony still decodes display frames because a genuine live preview is needed. An in-flight native operation may take time to acknowledge cancellation; this is not a claim of measured zero-latency shutdown.

On uses the existing shared five-Hz pipeline and sequence tracker. Acquisition runs at most about every 0.75 seconds; healthy automatic tracks re-evaluate at most every 2.5 seconds. At most two generic proposals are region-classified per acquisition; at most four are retained for manual targeting. Scene classification is separately throttled. Measured coaching stays opt-in, gated by AI Guidance and suppressed during a zoom ramp.

## Selection policy

Native human/body/face and cat/dog detectors supply semantic boundaries. Saliency supplies proposals, not semantic object detection. Sampled image color/detail separation, saliency prominence, visible occupancy/location and edge-density evidence feed relevance alongside detection/category/classification confidence. Background class hints receive a soft penalty. Architecture can qualify through confident classification, visual prominence and sustained central framing; manually selected scenery/ordinary/background objects remain possible. A crop classification does not turn a saliency rectangle into a semantic person/pet boundary.

Default relevance threshold is 0.68, configurable in Settings from 0.55–0.85. Below-threshold, tiny, invalid, flat or unsupported regions produce no automatic selection. Generic proposals require measured isolation and visual evidence (or the architectural exception); strong isolated unknown objects can qualify conservatively. Temporal acquisition requires at least two semantic observations or three generic observations plus dwell; a long gap clears pending acquisition. Category is a weighted prior, not an unconditional priority bucket, and size alone never chooses a subject.

Once selected, actual Vision tracking retains the subject. A different automatic proposal must exceed the retained relevance by 0.14 and persist across at least three observations and a 1.5-second challenger dwell. One weak frame hides unconfirmed boundaries but retains tracking intent; repeated/lasting failure ends the track. Box smoothing/opacity remain. No old rectangle is presented as a new observation.

Manual tap focuses independently through native AVFoundation or advertised Sony touch AF. With AI on, it attempts actual detected boundaries, bypassing automatic relevance. If none are reliable, only the normal native focus indicator appears. Manual intent stays prioritized; **… → Automatic subject selection** resets it and rearms an automatic session. AI off/on also starts a new session. Off-state photos do not acquire AI subject/scan metadata.

Guidance stays contextual and debounced. No selected subject normally gives Point at a subject. Confident full-frame landscape classification can give measured level/lighting guidance or Take in the scene; tap a subject, without an object box, ready state or automatic zoom. No unsupported lower-angle, aesthetic or generative scene instruction is added.

## Zoom and Sony

Existing native margin/quality limits, fresh real motion, configured hold, one zoom per armed session and manual cancellation remain. Hold timing uses the evaluation time after inference, not an earlier time while analysis may have been busy. During a ramp, the achieved zoom reprojects the last confirmed region and tracking-only inference checks it; no acquisition can redirect the ramp. Loss of a confident tracked observation requests cancellation on the camera queue on that analysis update. Threshold/source changes and disabling AI also cancel. There is no claim of measured latency or successful lens-transition tracking before device tests.

Sony transport, descriptor discovery, genuine received preview, capability gates, capture/transfer and source selection are preserved. It uses the same selector and AI toggle. No phone video substitutes for Sony frames and no Sony lens-zoom command exists. Remote focus is attempted only if advertised. Firmware/device compatibility remains experimental and requires the independent [Sony tests](SONY-INTEGRATION.md).

## Automated and structural verification

18 new XCTest functions cover selection/loss/dwell/hysteresis/threshold/manual priority, flat versus isolated image evidence, landscape guidance, settings migration and stale activation/source results. They use synthetic candidate/image evidence to exercise the policy; they do not verify Vision model accuracy on real scenes. All 87 native XCTest functions remain in the shared target. **None executed in this Linux workspace.**

Passed: Swift grammar for 43 files (36 app / 7 test), project/source references, plist/privacy/scheme/permissions, resources/fonts, both free workflow scripts, generator determinism and whitespace. The local Xcode build was attempted and failed because xcodebuild is unavailable. A Docker-based pure-logic test attempt was cancelled before execution. No simulator, Swift compiler, Apple SDK, iPhone 16 Pro Max or Sony camera is available for native verification here. The 1.5 cloud compile timeout was addressed in 1.5.1; its native rebuild result has not been supplied. New native compilation/testing must be confirmed by Codemagic.

## Physical iPhone 16 Pro Max acceptance — all pending

1. Empty wall: enable AI, wait/move; no forced subject or zoom. Observe lighting changes and repeated patterns.
2. Empty room: furniture/doorframes/floor should remain unselected unless strong intentional framing or a manual selection supplies evidence.
3. Person in a room: body/face proposal generally outranks furniture; verify full-body margins, lighting and edge cases.
4. Cat/dog on a couch: pet generally outranks couch; check motion, occlusion and real detection confidence.
5. Single product on a table: a clearly isolated product may qualify after sustained evidence; no assumption that every product/class is recognized.
6. Landscape: real scene-level guidance where supported; no invented object rectangle, readiness or zoom.
7. Architecture: a deliberately framed building/landmark can qualify or be manually selected; no blanket class exclusion.
8. Multiple people: steady tracking; small score fluctuations cannot jump subjects. A strong challenger must persist. Tap selection stays prioritized.
9. Tap background object: native focus always works. AI box appears only if actual boundaries are reliable. Menu reset returns to automatic selection.
10. AI off: no subject boxes/composition advice/auto zoom/Vision or coach inference. Native preview, AF/tap, manual zoom, capture and exposure work. VoiceOver announces Off.
11. AI on: yellow highlight and On announcement, actual inference resumes, no stale box from earlier session. Toggle rapidly and change sources.
12. Pinch/lens change during a ramp: cancel promptly; no repeat zoom until rearmed. Remove/occlude the subject during ramp: cancel on observed loss without framing the old background.
13. Switch source while tracking/zooming/inference is busy: no stale source box/message/automatic command. Independently repeat with genuine Sony frames.
14. Low-confidence/no confident detection: no box; no false ready/automatic shutter. Confirm threshold persistence and AI preference migration/relaunch.

Also test existing shutter/gallery/series/RAW/export/reference/exposure/lifecycle and preview quality. Inspect inference frequency, heat, battery use and cancellation latency with Instruments on the device. Build latest main with ios-sideload, which still runs the full native test suite before archive/IPA packaging, and install over the AltStore app to preserve its library.
