# Focal 2.0.1 / build 17 — professional camera upgrade

This is the build 17 baseline report. Build 18 updates advice timing, PRO lens switching, subject eligibility and automatic crop geometry; see [Guidance refinement](GUIDANCE-REFINEMENT.md) for the current behavior and checks.

Build 17 corrects the two `Section` initializers in Precision settings to use explicit content, header and footer closures. Codemagic reported that build 16 did not compile because its title-plus-footer calls selected no supported SwiftUI initializer. The correction awaits a fresh native build; existing functionality and test requirements are preserved.

## Outcome and verification status

This is an incremental extension of Focal 1.12, preserving the existing camera session, capture/gallery/editor, detector/tracker/composition/zoom coordinator and Sony adapter. The app still opens directly to the iPhone camera with optional intelligence. No new app dependencies, proprietary camera SDK, backend, account, paid signing entitlement or downloaded ML model was introduced.

**Implemented in source, not verified on hardware.** This workspace has no Xcode/Apple SDK, simulator, iPhone or Sony camera. Stage builds and the final simulator build/test were attempted and exited 127 (`xcodebuild: command not found`). Structural checks are separate from Swift grammar/type checking or runtime tests. Codemagic still runs native XCTest before IPA archiving.

See the [pre-change audit](PROFESSIONAL-AUDIT.md) for feature classifications and baseline history.

## Preserved and repaired

- Direct camera launch; permissions/retry, photo capture/maximum photo dimensions, supported RAW/ProRAW, zoom stops/pinch, AF, white balance, sharing/export, favorites/collections, review and phone-only editing restrictions remain.
- Standard preview now uses the selected capture aspect instead of a tighter immersive crop. Other selected ratios and the full received Sony frame retain their actual aspect. RAW originals retain the full sensor frame.
- Media-services reset can rebuild the session. A failed default setup retries with a real wide camera; failed explicit lens selection restores the previous device. These are targeted recovery paths, not a claim that every historical "Camera unavailable" event was reproduced/fixed.
- Manual focus/exposure are protected from tap and AI focus/metering. Manual focus hides the tap focus-request marker; AI subject selection remains separate from hardware focus state.
- User tap cancels inference and resets the prior subject/layout/motion state. Existing scan/ramp generations, detail caps and immediate manual zoom cancellation remain.

## Original interface and AUTO/PRO

Charcoal `#101112`, panels `#232527`, amber `#EDCA67`, primary text `#F7F7F7`, muted text `#9EA3A8`, restrained green, system typography, FOCAL wordmark, source subtitle, compact format/mode/aspect/exposure strip and an original focus-diamond intelligence mark replace the prior reference-based identity. White shutter and gallery remain. Subject indicators use amber corners for every supported category; guidance uses Focal wording. Existing caption choices remain, with Focal field-note wording for new scans.

AUTO retains AE/AWB/continuous AF. PRO opens real supported ISO/shutter/EV/WB/focus controls while the viewfinder stays visible. The strip filters unsupported parameters and offers actual discovered physical/virtual lenses. Slider edits are coalesced; opening a parameter does not change its value. Values shown are polled from hardware, not optimistic requested settings. AUTO/reset restores the associated automatic controls.

Important controls:

- AVFoundation custom exposure locks **both ISO and shutter**. Changing either retains the other's actual value; exposure AUTO clears the pair. Aperture remains read-only metadata. EV adjustment is available with automatic exposure, including PRO with AE still active.
- WB requests temperature/tint, converts them through device gains and clamps gains to the supported hardware range. The displayed temperature/tint come from the resulting actual gains. The temperature slider's 2000–10000 K range is a request range, not a claimed device capability range.
- Focus uses supported lens-position locking, normalized near 0/far 1. Unsupported virtual-camera focus/custom exposure require choosing a supported physical lens. The native center loupe magnifies the real preview without changing capture zoom.
- Long manual exposures can reduce preview cadence. Manual exposure/WB/focus survive guidance, taps and gallery return; unsupported state is clamped/reset explicitly when a different device is selected.
- JPEG/HEIF selection uses advertised codec support; unsupported HEIF falls back visibly to JPEG. Bayer RAW uses a JPEG companion. ProRAW retains its supported processed codec. ImageIO determines JPEG/HEIF file extensions; aspect crops/edits can create JPEG derivatives while retaining the original HEIF file.

## Intelligence and Focal Intent

The bottom-right button still toggles guidance on/off. Off means no Vision subject/planning inference, boxes, composition instructions or AI zoom. Independently enabled pixel tools may still sample frames without Vision.

Auto/Portrait/Pet/Product/Architecture/Landscape intents persist and affect actual candidate acceptance, layout priorities and crop limits. Portrait/Pet narrow the category pool; Product favors isolated objects; Architecture favors supported geometry and preserves context without automatic zoom. Landscape performs global classification/measurements with **no forced subject box**. Explicit tap intent remains dominant in subject-oriented modes. Models can miss/misclassify objects; intent does not imply perfect semantic understanding.

The existing sixteen-layout comparison and 22-technique guide remain. Portrait uses restrained crop limits. Only supported centered crops can auto-zoom; negative space, groups, enclosing frames and context layouts retain their surroundings. Hold and readiness still require real observations and steadiness, and manual pinch/lens changes cancel automation. No permanent grid/crosshair was added.

## Precision and AutoTune

Menu → Focal Precision contains independent persisted histogram, highlight warning, focus peaking and AutoTune switches. Each defaults off. A separate serial queue/admission gate samples a bounded 600px copy at most once per 0.35 seconds. It releases native capture buffers and does not wait for Vision or replace preview/photo pixels. Source, settings, geometry and menu/stop generations reject obsolete results. Real Sony frames can also supply pixel tools.

- Histogram: 64 luminance bins from the actual visible sample, including mirror/aspect-fill projection. Count totals equal sample pixels.
- Zebra: RGBA stripes where sampled luminance ≥0.98. Preview near-white pixels are not necessarily clipped RAW sensor values.
- Peaking: highlights strong two-sided local luminance differences (>0.16), excluding extreme black/white pixels. It is an approximate edge aid; noise, texture, resizing and sharpening can trigger it. It is not an optical-focus verdict.
- AutoTune: measured brightness/shadows/highlights, actual ISO/shutter, fresh phone rotation, and relative tracked-subject movement when AI is running and phone steadiness/unchanged zoom permit it. Relative movement is image-space motion, not world speed or proof that the camera has no translation. No hidden detector is enabled when AI is off.
- Recommendations explain their evidence. A near-white fraction >12% may suggest an explicit one-third-stop EV trial in AUTO. No setting changes happen by default. Apply is rejected for PRO, manual exposure, Sony, paused/capturing state, invalid/future measurements or measurements older than two seconds. Hardware still clamps EV. Other recommendations remain advice.

Performance/heat, WB/exposure response and overlay accuracy require device measurement. A bounded processing design is not proof of smoothness on every device.

## Insights and Compare

Gallery → photo → Focal Insights decodes the actual saved/current/original image with orientation correction. A serial actor reuses the existing detectors for single-image inspection, with no fabricated temporal tracking frames. A bounded 12-report cache stores measurements/metadata, keyed by file path/date/size/intent, not full-resolution photos.

Insights includes exposure/headroom, local contrast as a sharpness proxy, measured shadows/highlights, detected candidate position/area, supported composition suggestions and actual file metadata. A no-subject result is valid; landscape boundary advice requires evidence. Corrupt/missing images fail honestly and remain unchanged.

Defined calculations:

- Mean luminance: sampled RGB using `0.2126R + 0.7152G + 0.0722B`.
- Near-black fraction: values <0.04; near-white fraction: values >0.96 in rendered-image analysis.
- Rendered headroom index: `100 × max(0, 1 − shadow fraction − highlight fraction)`. It measures tonal occupancy, not artistic exposure correctness or RAW dynamic range.
- Edge energy: mean absolute neighboring luminance difference at the existing normalized sample size. It is not calibrated optical sharpness, and noise/texture can inflate it.
- Composition: actual supported subject geometry and the existing transparent heuristic layout ranking, not an objective aesthetic score.

Gallery → Compare → select two images offers side-by-side and a reveal slider, camera originals/current derivatives, exposure/edge-energy differences, positioning/layout observations and metadata comparison. Differences use **B minus A** and percentage points where appropriate. Different subjects/aspects/crops are flagged; images are not registered automatically. No overall winner, deletion or modification occurs. Existing burst selection is labeled "Technical pick", not an aesthetic winner.

## Focal Link / Sony research and milestones

Reviewed [rocc](https://github.com/simonmitchell/rocc) (MIT) and [remote-camera-control-rs](https://github.com/Streetblock/remote-camera-control-rs) (MIT/Apache-2.0). They distinguish older ScalarWebAPI from newer DigitalImaging/PTP/IP and gate controls by capabilities. The Rust reference reports an ILCE-7M3 ScalarWebAPI discovery, which informs investigation but does **not** validate this build/firmware/device. No source from either project was copied, and neither was added as a dependency. No modern Sony Camera Remote SDK compatibility is assumed.

[Apple's local-network guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) and [multicast entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast) distinguish local privacy permission from multicast signing entitlement. To preserve personal sideloading, this update uses original **bounded unicast descriptor discovery**, not an unentitled SSDP multicast claim.

The camera address no longer defaults to an assumed fixed IP. Find camera on Wi-Fi derives private IPv4 candidates from the real `en0` subnet (up to 64, four concurrent requests), prioritizes a previously verified descriptor address only within the current subnet, excludes self/network/broadcast/public addresses and accepts only valid real ScalarWebAPI descriptors. A discovered service is not labeled connected: actual decoded camera frames are still required. The discovered descriptor URL feeds the existing connection flow; manual address entry remains available. The bounded search can miss devices outside its candidate subset or cameras exposing only another protocol.

| Milestone | Source status / remaining verification |
| --- | --- |
| Wi-Fi join | Explicit iPhone Settings instructions; Focal does not fake joining or use restricted automatic hotspot entitlement. |
| Genuine discovery/identification | New descriptor search and real XML model/endpoint parsing; physical local-network/firmware test pending. |
| Live view/decoding/display | Existing genuine stream/JPEG decoder/preview retained; new-build A7 III test pending. |
| Shared AI/pixel tools | Real received frames enter shared analysis; no phone/demo substitution. |
| Remote shutter/focus | Existing advertised commands/control serialization/cleanup retained; hardware validation pending. |
| Exposure metadata | Existing received telemetry remains read-only; missing/unverified values remain absent/dashes. |
| Disconnect/reconnect | Existing generation, cleanup, recovery and source-switch handling retained; network-loss test pending. |
| Other protocols/models | PTP/IP implementation and A6100 verification remain separate work; no unsupported Sony lens zoom or RAW transfer. |

## Files and dependencies

Major new files: `CameraControls.swift`, `ProfessionalControlsView.swift`, `PhotographyIntent.swift`, `PrecisionAnalysis.swift`, `PrecisionOverlayView.swift`, `AutoTune.swift`, `PrecisionSettingsView.swift`, `PhotoInsights.swift`, `PhotoInsightsView.swift`, `PhotoCompareView.swift`, `SonyDiscovery.swift`, and `ProfessionalCameraTests.swift`.

Main integrations: existing CameraController/CameraView/CameraPreview, settings/options, tracker/selector/planner, theme/guidance/overlay, gallery/library/metadata, Sony connection/adapter, project generator/resources and reports. Smaller changes update original surfaces/wording and existing regression expectations. Full changed-file inventory accompanies the source commit; working providers/capture/editor were extended rather than replaced.

Native app dependencies remain Apple frameworks only. Network-interface inspection adds Darwin's existing OS API. No package manager, external model, SDK or entitlement was introduced.

## Tests and actual hardware work

34 new XCTest functions cover control locks/range safety/unsupported capabilities, intents/manual intent override, pixel histogram/masks, AutoTune evidence/PRO/source/staleness guards, subnet constraints, comparison measurements, scene guidance without boxes, preference/manifest compatibility and honest missing/corrupt file handling. Total **235 registered native tests**; **zero executed here**.

Structural checks pass: all 64 app and 17 test files registered, lexical delimiter balance across 81 Swift files, deterministic generator, source/resource paths, plists/shared scheme, assets/fonts, cloud YAML/shell syntax and `git diff --check`. These are not Swift syntax/type, image rendering or performance checks. Stage/final Xcode commands failed because Xcode is absent. Actual hardware tests performed: **none**.

## iPhone 16 Pro Max test

1. Windows: run Codemagic **ios-sideload** on latest `main`. Confirm its native tests and archive pass; download `Focal-unsigned.ipa`. Install over the existing Focal with AltStore Classic, keeping its local library. Refresh personal signing as usual.
2. Confirm Focal 2.0 in settings, direct camera launch/default iPhone and allow/deny/retry permissions. Check preview edges against the saved crop in each ratio, front mirroring, capture, RAW/ProRAW, HEIF/JPEG, originals and Photos export.
3. Toggle AUTO/PRO. Use only offered parameters/lenses; select a physical lens if manual exposure/focus is absent on a virtual device. Compare displayed values with the actual capture EXIF. Verify linked exposure AUTO, WB gains, manual focus/loupe, fixed aperture, gallery return and session recovery.
4. With manual exposure/focus/WB set, tap/select subjects, turn AI on/off and pinch. No manual lock should be overwritten. Re-enter AUTO explicitly to restore automation.
5. Test intents with people, pets, objects, landmarks and empty scenes; Landscape should show no forced box. Check coordinates, stability, subject switching, contextual crops, no cropped-out subject and immediate manual zoom priority.
6. Enable histogram/zebra/peaking separately with AI off and on. Use black/white/edge scenes; observe approximate limits. AutoTune must not silently alter PRO; explicit AUTO EV trial must obey current ranges and expiry.
7. Open Insights on captures and corrupted/missing-file error paths; compare two originals/current derivatives in both layouts. Verify file metadata, measured differences and unchanged originals.
8. Measure native preview/inference/precision cadence, memory and heat in low light, movement, long manual exposures and zoom. Check VoiceOver, larger text and safe areas/sheets on the actual phone.

## Sony A7 III test

1. Keep a memory card installed, still-photo mode selected, camera awake and Ctrl w/ Smartphone enabled. Join the camera's displayed DIRECT Wi-Fi in iPhone Settings and remain on it even without internet.
2. Open More → Camera Source → Sony → Focal Link. Allow Local Network, then Find camera on Wi-Fi. Select a real discovered descriptor and Connect. If the bounded search misses it, enter the actual camera address from network configuration; do not infer a fixed address.
3. Record model/firmware/mode, descriptor URL, advertised methods, actual decoded frame dimensions/cadence and control errors. Only a changing genuine camera scene establishes live view.
4. Retest the existing remote shutter/JPEG transfer/touch focus and received metadata; unsupported controls must remain absent. Compare transferred JPEG with the camera-card original to identify stream/transfer limits. RAW stays on the Sony unless a verified transfer path is added.
5. Test shared intents/guidance and pixel overlays on actual received objects/scenes; lens zoom remains manual. Phone gyro is not Sony motion, and low-resolution camera JPEG cannot gain sensor detail through upscaling.
6. Disconnect/reconnect, deny permission, sleep the camera, remove Wi-Fi and switch to iPhone during connection/capture. No stale Sony frames/commands or phone/demo replacement should appear. A6100 requires its own independent test matrix.
