# Focal — a little perspective

A native iPhone camera app inspired by Framed’s **point → guide → capture** workflow, with Focal branding and a camera layout based on the supplied reference screenshots. SwiftUI, AVFoundation, Apple Vision, and Core Motion. No third-party SDKs, account, API key, or backend.

**No Mac or paid developer membership?** Follow [INSTALL-FOR-FREE.md](INSTALL-FOR-FREE.md) for Windows + AltStore Classic personal sideloading. The `ios-sideload` cloud workflow runs regression tests, then builds an unsigned IPA for AltStore to sign. Only the free `ios-sideload` and `ios-check` workflows are included.

## Open and run

1. Open **Focal.xcodeproj** in Xcode 16 or newer on a Mac.
2. Select the **Focal** scheme. For a physical iPhone, select your Apple development team in Signing & Capabilities and replace `com.example.focal` with a unique bundle identifier.
3. Choose an iPhone running **iOS 17 or newer**, build, and run.
4. Allow Camera access on the camera screen. If camera hardware is unavailable, choose **Explore the demo**.

The project is already generated. `python3 scripts/generate_project.py` regenerates its deterministic configuration if files are added. There are no dependency installation steps.

## Included

- Portrait rear-camera preview, maximum supported photo dimensions with quality prioritization, original JPEG persistence, tap-to-select/focus, and device-aware lens/pinch zoom.
- On-device face/saliency selection followed by Vision object tracking on a 640-pixel analysis buffer, preview crop mapping, stable center/thirds targets, selectable thirds corners, motion level, and a 650 ms alignment dwell before the ready state.
- Screenshot-inspired black camera layout, green subject labels, yellow level, white shutter, lens buttons, grouped Settings and aspect popup.
- Persistent grid, level, shutter sound, scan saving, caption style, Photos export and RAW retention settings. Shutter muting requires supported iOS 18+ hardware/configuration.
- 3:4, 4:5, 1:1 and 9:16 capture crops; optional RAW/ProRAW on supported cameras; original JPEG and DNG retention.
- Private local photo library with thumbnails, favorites, deletion confirmation, native sharing, and explicit export to Apple Photos using add-only authorization.
- Camera denial/unavailability and interruption handling. A labeled, offline demo with working save/export/gallery flows.
- Privacy manifest, app icon, shared scheme, and 22 XCTest regression tests covering composition, preview geometry, crops, scan captions, persistence and settings.

## Validation status

This project was authored in a Linux workspace without Xcode, an Apple SDK, or an iOS simulator. **It has not been compiled or run on iOS here.** Swift syntax, resource references, plist/scheme validity, and project structure are checked separately; these checks do not replace an Xcode build or device testing.

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
- Grid/center/thirds modes, leveling, tap focus, shutter while searching, repeated capture.
- Background/foreground, opening Settings/library, incoming calls, interruption recovery.
- Relaunch and verify persisted shots/favorites; export permissions and denied export; share and deletion.
- Low light, multiple subjects, close subjects, large text, VoiceOver, and smaller iPhones.

## Scope and behavior

The guide uses Apple Vision face detection and saliency to select a subject, then tracks that region. It suggests a stable thirds intersection or the center and lets you select another corner. Tap selects a subject; Rescan restarts automatic selection. It is a composition heuristic, not an aesthetic scoring system. It can miss or misidentify subjects. Readiness means the detected subject is near that point and the phone is level; it does not certify focus, sharpness, or artistic quality. Core Motion estimates phone roll, not a visual horizon. Rear virtual cameras use the available ultra-wide/wide/telephoto lenses where supported. Displayed zoom is relative to the wide lens; pinch zoom is capped at 6×. Intermediate and high zoom can crop the image and reduce detail. Portrait orientation is supported. No filters, subscriptions, front camera, or cloud analysis.

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
