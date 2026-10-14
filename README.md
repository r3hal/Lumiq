# Focal — professional camera and photography tools

A native SwiftUI camera with original charcoal/amber identity, optional Focal Intelligence, real AUTO/PRO controls, photography intents, live precision tools, captured-image Insights and read-only Compare. Existing capture/gallery/editor and Sony services are preserved. Apple frameworks only; no account, API key or backend. The app opens directly to the iPhone camera. AI and precision tools start off; the photographer controls automation.

**Latest: Focal 2.5.2 / build 25 — automatic zoom readiness fix.** Temporary zoom gates no longer finish the selected shot, and restoring camera settings no longer registers manual override. Readiness requires verified real zoom and a stopped motor, or a stable measured current frame. [Implementation, diagnostics and iPhone checks](docs/intelligence/READY-ZOOM-FIX-2.5.2.md). Structural validation passes; 370 registered native tests await Codemagic, and physical iPhone behavior remains unverified here.

For private developer evaluation, run Codemagic **`ios-evaluation`**, install its IPA with AltStore, and open **Menu → Camera Settings → Developer Intelligence Lab**. Import and label your cat/object/landscape photos, compare the frozen build 18 guidance with the updated engine, and export self-contained JSON. Normal `ios-sideload` omits the developer lab from Release; both workflows run native tests before archiving.

PRO exposes actual supported ISO/shutter, EV, WB, focus/loupe and discovered lenses, with an always-visible LENS menu and a return to Automatic lenses. Aperture stays informational. Menu → Focal Precision enables measured histogram/zebra/approximate peaking/AutoTune independently of AI. AI Settings selects intent. Gallery exposes Insights and two-image Compare. Focal Link prefills `192.168.122.1` unless a different valid camera host was saved. Discovery searches real camera descriptors on the joined Wi-Fi subnet; a genuine received frame is still required before reporting live view.

**No Mac or paid developer membership?** Follow [INSTALL-FOR-FREE.md](INSTALL-FOR-FREE.md) for Windows + AltStore Classic personal sideloading. The `ios-sideload` cloud workflow runs regression tests, then builds an unsigned IPA for AltStore to sign. Only the free `ios-sideload` and `ios-check` workflows are included.

## Open and run

1. Open **Focal.xcodeproj** in Xcode 16 or newer on a Mac.
2. Select the **Focal** scheme. For a physical iPhone, select your Apple development team in Signing & Capabilities and replace `com.example.focal` with a unique bundle identifier.
3. Choose an iPhone running **iOS 17 or newer**, build, and run.
4. Allow Camera access on the camera screen. If camera hardware is unavailable, choose **Explore the demo**.

The project is already generated. `python3 scripts/generate_project.py` regenerates its deterministic configuration if files are added. There are no dependency installation steps.

## Included

- High-resolution 4:3 live preview format selection with continuous focus, exposure and white balance; portrait rear-camera preview, maximum supported photo dimensions with quality prioritization, original JPEG persistence, tap-to-select/focus, and device-aware lens/pinch zoom.
- On-device human/face/cat/dog/saliency selection followed by Vision object tracking on a 640-pixel analysis buffer, preview crop mapping, intent-aware automatic layouts, center/thirds overrides and selectable thirds corners, motion level, and a 650 ms alignment dwell before the ready state.
- AI Guidance on → meaningful subject → motion-verified hold → appropriate smooth automatic zoom, with a yellow subject box, directional bottom guidance, and subject-specific final advice. One zoom per armed AI session; pinch/lens controls cancel automation.
- Original charcoal/amber camera layout, refined subject corners, clean default preview, real AUTO/PRO strip, white shutter, lens controls and native settings sheets.
- Persistent AI Guidance toggle (off on upgrade/fresh install), subject selectivity, optional grid/level (off by default), steady-hold duration, shutter sound, scan saving, caption style, Photos export and RAW retention settings. Shutter muting requires supported iOS 18+ hardware/configuration.
- 3:4, 4:5, 1:1 and 9:16 capture crops; optional RAW/ProRAW on supported cameras; original JPEG and DNG retention.
- Private local photo library with thumbnails, favorites, deletion confirmation, native sharing, and explicit export to Apple Photos using add-only authorization.
- Camera denial/unavailability and interruption handling. A labeled, offline demo with working save/export/gallery flows.
- Privacy manifest, app icon, shared scheme, and 294 XCTest functions covering controls, intent, pixel tools, composition, preview geometry, Sony protocol/capture, editing, persistence, intelligence acceptance cases and evaluation metrics (native execution pending).

## Composition planning (1.12, build 15)

Automatic composition now compares supported layouts using real viewport pixels and detected subjects, instead of forcing centered phone framing. It considers thirds, golden-ratio placement, symmetry, negative space, tight framing, leading lines, diagonals, enclosing frames, balance, triangles, odd groups, repetition, layered context, background simplification and color contrast. Landscape horizon advice requires both scene classification and an observed horizontal boundary.

The card shows the selected technique and guides the camera toward its target. Center/Thirds remain explicit menu overrides. AI Settings adds persistent Composition Planning and a guide to 22 common techniques. People, pets and named objects share the planner; generic object/background labels remain excluded. In Automatic mode, evaluated thirds/golden-ratio crops can now guide the phone to a pre-zoom point, then zoom the subject onto the final mark. Detail limits, measured hold and immediate pinch priority remain. Sony uses the same guidance with manual lens controls.

See [research, implementation and device checks](docs/COMPOSITION-PLANNING.md). The planner ranks visible supported options; it does not guarantee a globally best photograph or infer gaze, depth, reflections or artistic intent. Structural checks passed. Native build/tests could not execute because Xcode is unavailable here; run Codemagic `ios-sideload` on latest `main`, then install its IPA over Focal using AltStore.

## Validation status

This project was authored in a Linux workspace without Xcode, an Apple SDK, or an iOS simulator. **It has not been compiled or run on iOS here.** Resource references, plist/scheme validity, lexical delimiter balance, and project structure are checked separately; these checks do not replace an Xcode build or device testing.

On a Mac, run:

```sh
xcodebuild -list -project Focal.xcodeproj
xcodebuild -project Focal.xcodeproj -scheme Focal \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
# Use an available simulator name shown by xcodebuild -showdestinations.
xcodebuild -project Focal.xcodeproj -scheme Focal \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Device checks before distribution:

- Fresh install: grant/deny camera, return from Settings.
- Portrait camera and captured-image orientation; compare subject-label placement with the real subject across supported iPhones.
- Clean default view, optional grid/level, internal center/thirds guidance, tap focus, shutter while searching, repeated capture.
- Background/foreground, opening Settings/library, incoming calls, interruption recovery.
- Relaunch and verify persisted shots/favorites; export permissions and denied export; share and deletion.
- Low light, multiple subjects, close subjects, large text, VoiceOver, and smaller iPhones.

## Scope and behavior

The optional guide uses Apple Vision human/face/cat/dog detection and saliency, a weighted relevance threshold and sustained acquisition to select a subject, then tracks that region. No selection is an expected result; saliency alone is not treated as object recognition. It suggests a stable thirds intersection or the center and lets you select another corner. With AI Guidance on, tap attempts real subject selection; Automatic subject selection in the menu resets manual intent. With AI off, taps focus without inference or subject boxes. It is a composition heuristic, not an aesthetic scoring system. It can miss or misidentify subjects. Readiness means the detected subject is near that point and the phone is level; it does not certify focus, sharpness, or artistic quality. Core Motion estimates phone roll, not a visual horizon. Rear virtual cameras use the available ultra-wide/wide/telephoto lenses where supported. Displayed zoom is relative to the wide lens; pinch zoom is capped at 6×. Intermediate and high zoom can crop the image and reduce detail. Portrait orientation is supported. No subscriptions or cloud analysis. Front/rear switching and Camera Source are available from the three-dot menu. Phone-only looks, adjustments, effects and frames are available after single captures and in photo detail; the camera preview remains unfiltered.

Photo capture requests the highest dimensions advertised by the active capture format and uses `.quality` processing for JPEG and ProRAW (Bayer RAW uses `.speed`). Actual dimensions depend on the device, lens, scene and AVFoundation. Photo detail displays the saved file dimensions. The default 3:4 JPEG and RAW files retain their captured bytes. Other aspect ratios create a full-resolution centered JPEG crop and retain the uncropped original. Scan references are separate, downsampled images (up to 1600 pixels) with a selected caption style. Gallery thumbnails and Vision analysis do not affect saved photo quality. This does not reproduce every Apple Camera feature such as its dedicated Night mode.

The demo shows a bundled sample photo; it does not analyze the sample in real time. Demo saves are labeled in the gallery. The demo is part of the native app and still requires a compiled installation or an iOS simulator.

Photos and the JSON library index live in Application Support. Exports are made on request or when automatic Photos export is enabled; deletion in Focal does not delete exported copies. Device backups may include the local library. Photos are not uploaded by the app. Uninstalling removes the app’s local library.

## Files

- `Focal/Camera`: session management, portrait preview, permission and capture UI.
- `Focal/Composition`: UI-independent composition state machine and overlay.
- `Focal/Library`: atomic local persistence, downsampled images, gallery, export/share.
- `Focal/App`, `Focal/Design`: settings, navigation, field guide, styling.
- `FocalTests`: composition, geometry, image derivatives, library compatibility and settings tests.

## Credits

Product reference: [Framed](https://shootframed.com/). Focal is an independent implementation and is not affiliated with Framed.

Bundled sample photograph: [lake and mountain scene](https://images.unsplash.com/photo-1476514525535-07fb3b4ae5f1), from Unsplash, used under the [Unsplash license](https://unsplash.com/license). Replace the sample if you prefer your own photography before distribution.

Subject names use Apple Vision’s on-device image classifier. Specific descriptions such as “mechanical RGB keyboard” are not guaranteed. RAW remains full-frame; exporting a cropped JPEG and its RAW creates separate Photos assets. No paid upgrade or purchase restoration is included in this personal build.

Caption font: EB Garamond, bundled under the SIL Open Font License in `Focal/Resources/Fonts/OFL.txt`.

## Automatic framing and preview quality (1.3)

A scan identifies and tracks a region, guides the user to center it, waits for the configured steady hold (default 900 ms, verified through phone motion), and ramps camera zoom once. The same tracked region is reprojected across the zoom transition. Manual zoom and cancel stop the ramp; opening Settings or the library stops the camera. Auto framing can be disabled in Settings. Camera shutter remains unavailable during the automatic zoom transition. Smart shutter is a separate opt-in setting; automatic zoom alone does not take a photo.

Automatic zoom fits the entire selected region with margins and uses the preview pixel budget and native lens positions to limit magnification. It does not digitally pan an off-center sensor crop: the user must move the phone as directed. Intermediate zoom can still reduce saved-photo detail, and low light can affect lens selection and noise. The native preview layer remains separate from the 640-pixel Vision analysis buffer. Preview format selection prefers a 4:3 format with at least 1920×1080 dimensions and 30 fps support, retaining the device’s supported photo dimensions; devices without such a format retain the system-selected format. Analysis is throttled to five updates per second. Settings displays the selected preview dimensions and automatic zoom cap for device diagnosis.

Bottom advice matches the demonstrated flow but is generated locally from subject class and measured alignment. It does not reproduce Framed’s proprietary scene model or guarantee detailed labels such as “sleeping gray cat.” Live-preview sharpness and lens transitions still need device comparison with the reference app.

## Audit update (1.4)

Read [the baseline feature audit and priority table](docs/FEATURE-AUDIT.md), [implementation report](docs/IMPLEMENTATION-REPORT.md), and [device acceptance checks](docs/DEVICE-CHECKS.md). No third-party dependencies or secret API keys were added.

- Three-dot menu (moved from the aperture control in 1.5): switch front/rear cameras, adjust exposure, import a reference, open Explore, or enable measured coaching and smart shutter. Front-preview mirroring and Vision selection use the same projection model.
- Aspect menu: preserves 3:4, 4:5, 1:1, 9:16 and adds actual 4:3/16:9 landscape crops. Crops stay within image bounds and preserve supported EXIF metadata.
- Reference overlay: native PhotosPicker imports a local image without broad Photos-read permission. Adjustable transparency; the overlay is never burned into captures. Reference is retained only while the camera view lives.
- Photo detail: tap the image for a zoomable full-screen viewer; edit the primary photo with Original/Amber/Soft Film/Silver/Faded, exposure, contrast, saturation, warmth, highlights, shadows, grain, vignette, ratio crops and 90° rotation. Compare with original; save named recipes or a new full-resolution JPEG copy. Only editing previews are downsampled. Edited derivatives use sRGB; original captures/RAW retain their original data/color encoding.
- Library: persistent named collections, existing favorites/share/export/delete, file metadata and measured technical scores. Photo series (Settings) take 3 or 5 sequential high-quality captures, retain every file, and label the highest measured candidate. This is not native high-speed burst capture or aesthetic best-shot judging.
- Smart shutter: opt-in, one capture/series per armed scan after the existing readiness dwell. Stops when inactive, busy, switching or automatically zooming; changing subjects/scan rearms. Manual captures consume the arm.
- Coach: opt-in, image measurements every two seconds, full-frame classification every eight seconds, conditional joint detection for a selected person. Lighting tips use luminance and clipping; background-busyness tips use edge density outside the tracked subject; distance tips use frame occupancy. Pose hints require confident nearby joints. These are transparent measured heuristics around native ML detection, not a generative photographer.
- Technical score: `100 × (0.6 × (1 − deep-shadow fraction − clipped-highlight fraction) + 0.4 × min(1, mean local contrast / 0.12))`. Shadows below 0.04, highlights above 0.96 in sampled luminance. Noise and textured backgrounds can inflate detail. Guide alignment separately measures distance to the target and phone roll; neither is an aesthetic rating.
- Explore: original field guide, practical challenges with capture counts and offline estimated golden-light windows. Optional location access is requested only by the location button and is not persisted, uploaded or added to captures; manual coordinates work without permission. Approximate geometry follows [NOAA’s published solar equations](https://gml.noaa.gov/grad/solcalc/solareqns.PDF), with a defined −4° to +6° window, one-minute sampling, and no weather/refraction/terrain model. Times use the iPhone’s timezone.

Camera live-filter rendering, generative scene/pose coaching, AI aesthetic ratings, exact proprietary Framed descriptions, dedicated Night mode and native high-speed burst remain unimplemented. They require a separate validated rendering/capture pipeline or a suitable bundled/securely hosted model. No nonfunctional buttons or fake scores represent them.

## Automatic composition update (1.5)

See [audit](docs/AUTO-FRAMING-AUDIT.md), [implementation and acceptance report](docs/AUTO-FRAMING-REPORT.md), and [Sony integration/testing plan](docs/SONY-INTEGRATION.md).

- Permanent crosshair removed; grid/level migrate off once and remain optional. Actual detected boxes persist after zoom, follow achieved zoom and clear on tracking loss. Tap acquisition no longer invents a rectangle.
- Debounced bottom guidance, fresh device-motion gating, configurable steady hold, aggregate drift checks and one appropriate zoom per scan. Completed framing retains a consistent target. Manual pinch cancels at gesture start using the achieved camera zoom.
- Top aperture button expands real mode/shutter/ISO/EV at the preview bottom. ISO/shutter are read-only, EV is adjustable on iPhone and aperture is fixed. Camera Source lives in **…**, while the yellow footer button remains Scan.
- Experimental, capability-discovered Sony wireless adapter with real received JPEG live view, shared Vision analysis, supported touch AF/capture and reported telemetry. It never substitutes iPhone video or sends Sony lens zoom commands. A7 III/A6100 firmware compatibility and transfer quality require independent physical testing.

Build the refreshed `main` branch with Codemagic `ios-sideload`, download `Focal-unsigned.ipa`, and install over Focal with AltStore Classic. Keep the app installed to preserve its local library. Structural validation passed; Xcode compilation and all 176 native tests still need the cloud build. No iPhone/Sony device checks were performed here.

## Compilation correction (1.5.1, build 7)

The 1.5 cloud build reported a Swift type-checking timeout in CameraView before any tests ran. Camera layout, lifecycle/preferences, sheets, previews, toolbar/menu, exposure strip and footer now have smaller opaque view expressions, with explicit numeric, color and collection types. The existing capture pipeline and 69-test suite are retained; the workflow still runs tests before IPA packaging. See [build-fix details](docs/BUILD-FIX-1.5.1.md). Local structural checks pass; a fresh Codemagic build must confirm native compilation and test results.

## Selective AI Guidance (1.6, build 8)

The existing bottom-right button is now **AI Guidance**: dark with a yellow outline when off, highlighted yellow when on, with VoiceOver On/Off values. Fresh/upgraded installs start off once; later explicit choices persist. Turning it off cancels automatic zoom and active inference, hides AI overlays and suppresses scene/coach processing on both sources. Native autofocus, tap focus, manual zoom, exposure and shutter remain available. Use **… → Automatic subject selection** to leave manual selection and start a new automatic session.

Detection proposals are ranked using actual confidence/category, saliency/local contrast, measured isolation, visible size/location, texture density and classification evidence. Configurable selectivity defaults to 0.68. Acquisition needs repeated observations; ordinary saliency regions require strong isolation or supported architectural context. Background categories carry a soft penalty rather than a permanent exclusion. Manual taps bypass automatic relevance but still need real reliable boundaries. Healthy tracking is retained; substantially stronger challengers require sustained evidence. Scene-classified landscapes can receive measured scene guidance without a box, readiness claim or automatic zoom.

See [audit](docs/SUBJECT-SELECTION-AUDIT.md) and [implementation/device checklist](docs/SUBJECT-SELECTION-REPORT.md). These are measured heuristics around native models, not a model of artistic value or a guarantee of user intent. Actual detector behavior and default thresholds need testing on the iPhone 16 Pro Max and independently on Sony live view. There are 87 registered XCTest functions; none have run here. Structural checks pass, but Xcode/Codemagic build and physical verification remain pending.

## Preview motion and Sony JPEG recovery (1.6.1, build 9)

The native preview connection is now reconfigured only when rotation/mirroring actually changes. A separate video callback admits one bounded analysis copy at a time, immediately releases the camera's full-resolution buffer, and drops inference backlog. Native analysis is capped at four admitted frames per second; selected-subject tracking remains active during pans/zoom while expensive discovery/coaching waits. Pinch requests coalesce to the latest target rather than accumulating camera configurations. Preview format selection retains the highest supported photo-dimension budget, prefers 60 fps at that budget when available, and fixes cadence to 60/30 rather than allowing 15 fps low-light behavior. Smooth slow focus and automatic low-light boost are disabled; automatic subject focus no longer changes exposure metering. Settings shows the chosen target and last observed buffer-delivery cadence. This may need higher ISO in low light; optical lens transitions, motion blur and digital magnification cannot be certified here.

Sony decoding now separates binary wrappers/padding from JPEG content, supports marker-framed streams, handles incremental segments/entropy/EXIF thumbnails, and resynchronizes after malformed frames. Images are displayed only after ImageIO validates and decodes them. Connection diagnostics report received bytes, framing, image and rejection counts if no view appears. A single rejected JPEG no longer immediately ends the connection. See [fix details and device retest](docs/PREVIEW-SONY-FIX.md). All 99 native tests still need Codemagic execution; motion quality and the A7 III connection need a physical retest.


## Sony preview and named guidance (1.7, build 10)

Sony now opens in its full Camera frame, requests the largest advertised wireless preview size, removes the 10 fps app limit and delivers the latest native decoded pixels directly to the preview. Analysis reuses those pixels on a separate bounded queue. Settings reports actual dimensions and incoming/decoded fps. Wireless camera resolution remains a physical limit. Camera frame captures keep the original transferred JPEG; optional crops remain available.

Selecting Sony enables automatic guidance with thirds targets. Specific recognized names replace generic saliency labels; repeated identity and measured boundaries are required. A target mark, camera-pan arrow and named footer instruction guide framing. Unknown regions stay unlabelled. The yellow button still disables guidance; Sony lens zoom stays on the camera. iPhone retains its opt-in guidance and native framing behavior.

See [implementation, limits and device retest](docs/SONY-SUBJECT-GUIDANCE.md). There are 111 native tests, including 12 new preview/identity cases; none ran in this Linux workspace. Codemagic compilation and physical performance/recognition tests are pending.


## Sony shutter recovery and richer recognition (1.8, build 11)

Sony capture now refreshes actual state, prepares supported autofocus, waits for advertised still capture, follows pending photos without re-firing and reports meaningful method-aware errors. Interrupted live view gets bounded reconnect attempts; a stream ending during a photo no longer cancels its control/transfer operation. Ambiguous shutter/transfer failures require checking the camera card before another press.

Guidance adds high-resolution crop classification, synonym consensus and local text/rectangle evidence for printed products. Subject-region exposure and background clutter now inform the footer, while searching/ready colors reflect actual guidance state. Unknown regions still do not receive invented names. These are offline recognition heuristics, not unlimited visual understanding.

See [implementation, limits and hardware retest](docs/SONY-CAPTURE-RECOGNITION.md). There are 130 native tests (19 new); none executed in this Linux workspace. Rebuild latest main with Codemagic ios-sideload, then install over Focal in AltStore. Native compilation and device results remain pending.

## Reference recordings update (1.9, build 12)

Phone guidance now follows search → confirmed subject → combined movement directions → centered steady hold → actual zoom → compact subject label, with cancel and restart controls. Foreground subjects can be evaluated in scenes containing peripheral people. Recognition remains on-device and confidence-gated; it is not Framed’s proprietary model.

Single iPhone captures open a black Looks / Adjust / Effects / Frames review screen with thumbnail looks, grouped HSL/grading/calibration, parameter rulers, grain/motion/light leak/scratches/halation/dust/glow/fringe/vignette, bordered frames and date stamp, undo/redo, Delete and Save. Retained supported RAW is actually developed; camera originals remain intact. Disable Review single shots in Settings to save directly. New editing is restricted to known iPhone captures and demo images, including when reopening library photos; Sony photos retain their existing capture and guidance flow.

See [reference features, limits and retest steps](docs/REFERENCE-VIDEO-UPDATE.md). All 150 native tests need Codemagic execution. Build latest main with ios-sideload and install over Focal using AltStore Classic.

## Phone acquisition and broader subject guidance (1.10, build 13)

Fixed the strict phone motion gate that prevented new acquisition during normal handheld movement. The stable-hold gate still controls automatic zoom/readiness. Phone and Sony now evaluate attention/objectness and rectangle proposals alongside people, with crop recognition for desks, tables, chairs, plants, trees and other supported subjects. Low-contrast furniture and natural foliage texture no longer require the same isolation test as anonymous background patterns. Nearby matching boundaries accumulate evidence; short tracking misses show a recovery instruction without stale boxes or ready claims.

See [causes, changes and retest](docs/BROAD-SUBJECT-GUIDANCE.md). Recognition is still probabilistic and cannot identify every item in every view. Native compilation and all 163 tests require Codemagic. Build latest main with ios-sideload and install over the existing AltStore app.

## Supplied 12-state UI design (1.11, build 14)

Updated the existing camera with exact warm-yellow/green accents, immersive safe-area layout, a lens pill, thin subject boxes/portrait brackets, compact measured guidance cards and actual hold progress. A native grouped options sheet opens source selection, separate Sony setup/connected status and AI Photography settings. The bottom-right button always toggles guidance; restart stays in options. New pet, tracking and smart-selection preferences control the real analysis pipeline and persist. Hold duration supports 1/2/3 seconds while keeping existing custom values.

Sony live view, advertised capture/focus and received exposure values reuse the existing services. Status is based on actual frames/model/stream data; mock battery/storage/signal values are not shown. Phone-only effects/editor restrictions remain. See [all twelve states, audit, verification and limits](docs/TWELVE-SCREEN-DESIGN.md). The Xcode build and tests were attempted but xcodebuild is unavailable here; all 176 native tests and iPhone/A7 III UI/hardware checks remain pending. Build latest main with Codemagic ios-sideload and install over Focal in AltStore.
