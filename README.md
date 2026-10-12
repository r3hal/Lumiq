# Focal — a little perspective

A native iPhone camera app inspired by Framed’s **point → guide → capture** workflow, with original branding and UI. SwiftUI, AVFoundation, Apple Vision, and Core Motion. No third-party SDKs, account, API key, or backend.

**No Mac or paid developer membership?** Follow [INSTALL-FOR-FREE.md](INSTALL-FOR-FREE.md) for Windows + AltStore Classic personal sideloading. The included `ios-sideload` cloud workflow builds an unsigned IPA for AltStore to sign; it has not yet been executed. For the optional paid TestFlight route, see [INSTALL-WITHOUT-A-MAC.md](INSTALL-WITHOUT-A-MAC.md).

## Open and run

1. Open **Focal.xcodeproj** in Xcode 16 or newer on a Mac.
2. Select the **Focal** scheme. For a physical iPhone, select your Apple development team in Signing & Capabilities and replace `com.example.focal` with a unique bundle identifier.
3. Choose an iPhone running **iOS 17 or newer**, build, and run.
4. Finish the welcome screen and allow Camera access. If camera hardware is unavailable, choose **Explore the demo**.

The project is already generated. `python3 scripts/generate_project.py` regenerates its deterministic configuration if files are added. There are no dependency installation steps.

## Included

- Portrait rear-camera preview and full-resolution JPEG capture, with tap-to-focus/exposure.
- On-device attention saliency detection at approximately 4 Hz, smoothed subject tracking, center/thirds guidance, motion level, and a 650 ms alignment dwell before the ready state.
- Grid and guide toggles, haptic feedback, independent shutter, and illustrated onboarding/field notes.
- Private local photo library with thumbnails, favorites, deletion confirmation, native sharing, and explicit export to Apple Photos using add-only authorization.
- Camera denial/unavailability and interruption handling. A labeled, offline demo with simulated guidance and working save/export/gallery flows.
- Privacy manifest, app icon, shared scheme, and eight XCTest composition tests.

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

- Fresh install: onboarding, grant/deny camera, return from Settings.
- Portrait camera and captured-image orientation; compare white-dot placement with the real subject across supported iPhones.
- Grid/center/thirds modes, leveling, tap focus, shutter while searching, repeated capture.
- Background/foreground, tab switching, incoming calls, interruption recovery.
- Relaunch and verify persisted shots/favorites; export permissions and denied export; share and deletion.
- Low light, multiple subjects, close subjects, large text, VoiceOver, and smaller iPhones.

## Scope and behavior

The guide is a composition heuristic built on Apple’s saliency model, not Framed’s proprietary AI and not an aesthetic scoring system. It selects the largest salient region and suggests a nearby thirds intersection or the center. It can miss or misidentify subjects. Readiness means the detected subject is near that point and the phone is level; it does not certify focus, sharpness, or artistic quality. Core Motion estimates phone roll, not a visual horizon. Only the rear wide camera and portrait orientation are included in this version. No filters, subscriptions, front camera, zoom switching, or cloud analysis.

The demo moves a simulated marker over a bundled sample photo to demonstrate the UI; it does not analyze the sample in real time. Demo saves are labeled in the gallery. The demo is part of the native app and still requires a compiled installation or an iOS simulator.

Photos and the JSON library index live in Application Support. Exports are only made on request; deletion in Focal does not delete exported copies. Device backups may include the local library. Photos are not uploaded by the app. Uninstalling removes the app’s local library.

## Files

- `Focal/Camera`: session management, portrait preview, permission and capture UI.
- `Focal/Composition`: UI-independent composition state machine and overlay.
- `Focal/Library`: atomic local persistence, downsampled images, gallery, export/share.
- `Focal/App`, `Focal/Design`: onboarding, navigation, field guide, styling.
- `FocalTests`: composition targets, stability, reset, direction, and invalid-input tests.

## Credits

Product reference: [Framed](https://shootframed.com/). Focal is an independent implementation and is not affiliated with Framed.

Bundled sample photograph: [lake and mountain scene](https://images.unsplash.com/photo-1476514525535-07fb3b4ae5f1), from Unsplash, used under the [Unsplash license](https://unsplash.com/license). Replace the sample if you prefer your own photography before distribution.
