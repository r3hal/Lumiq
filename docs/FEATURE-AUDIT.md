# Feature audit and implementation plan — baseline 2d92247 (Focal 1.3)

This audit was written before application-code changes. Every source folder, screen, shared component, native service, project generator, resource manifest, test suite and build/install document was inspected. There are 18 app sources and 3 test sources. No package manifest, hooks, web framework, backend, API credentials or external service exists.

Architecture: SwiftUI iOS 17+, ObservableObject/Published controllers and EnvironmentObject settings/library; UserDefaults settings; JSON index and protected local JPEG/DNG/scan files; AVFoundation photo session with a serial camera queue; a separate Vision analysis queue throttled to 5 Hz; Core Motion gravity level. Native NavigationStack inside gallery, detail, Settings sheets and field guide. Camera is the root; no tab bar. Core Image is currently used only for analysis downsampling and aspect crops. Deterministic Python Xcode project generation; Codemagic Xcode 16.4 checks then unsigned IPA for AltStore. No third-party SDKs.

Status legend requested: ✅ Implemented and working; 🟡 Partially implemented; ❌ Missing; 🔴 Implemented but broken. Native functionality has source implementations, but this Linux workspace has no Apple SDK, Swift compiler or simulator. It would be misleading to classify it as proven working on an iPhone, so implemented native features are marked 🟡 with their evidence. The user's prior preview feedback confirms an installed camera flow but does not verify this commit. No hardware feature has been tested by this agent.

Verified source findings:

- No placeholder subscription/purchase actions. Settings actions, shutter, scan, export, sharing and favorites reach real code.
- SubjectAdvice is a fixed template selected by local classification, not a generative scene coach. Aesthetic/quality ratings do not exist. Demo is an explicitly labelled static sample.
- Failed camera setup can leave input/output objects attached while `configured` remains false; retry is not transactional. Essential recovery needs repair.
- A stopped/cancelled ramp can leave stale tracker coordinates briefly; cancellation generations reduce stale requests, but lens transitions still need hardware checks.
- Camera `.checking` currently falls through to an unavailable UI instead of a loading state.
- RAW is capability checked; silent shutter needs supported iOS 18+ capture output. Level currently reports zero when gravity is unavailable, implying a level phone without evidence.
- Full 3:4 JPEG bytes are retained; other ratios crop a derivative and retain the original. Integral crop rounding can extend beyond odd-sized images. Crops currently discard EXIF metadata.
- An old reference scan can survive reset until a new frame arrives. PhotoImage loads can finish after cancellation and replace a newer image.
- Gallery deletion commits the index before file cleanup, which protects the index but can leave orphan files. Storage reflects referenced files only.
- Full-buffer camera output feeds a smaller 640-pixel Vision buffer; it is not the displayed native preview. Classifier runs only periodically. Native full-resolution capture is separate; no camera filter exists.
- WelcomeView and RoundToolButton are unused historical components. They will not be rebuilt or used to justify duplicate navigation.
- Photos export correctly uses add-only authorization. Reference import should use PhotosPicker without broad library-read permission. Location permission should be requested only by a user action.

| Feature | Current Status | Existing Implementation | Required Work | Priority |
|---|---|---|---|---|
| Live camera preview | 🟡 | CameraController, CameraPreview, CameraView, CameraSettings; real native APIs | Preserve; test on hardware. Fix recovery, motion availability and export denial UX. | P0 |
| Photo capture | 🟡 | CameraController, CameraPreview, CameraView, CameraSettings; real native APIs | Preserve; test on hardware. Fix recovery, motion availability and export denial UX. | P0 |
| Pinch-to-zoom and zoom controls | 🟡 | CameraController, CameraPreview, CameraView, CameraSettings; real native APIs | Preserve; test on hardware. Fix recovery, motion availability and export denial UX. | P0 |
| Tap-to-focus | 🟡 | CameraController, CameraPreview, CameraView, CameraSettings; real native APIs | Preserve; test on hardware. Fix recovery, motion availability and export denial UX. | P0 |
| Flash controls | 🟡 | CameraController, CameraPreview, CameraView, CameraSettings; real native APIs | Preserve; test on hardware. Fix recovery, motion availability and export denial UX. | P0 |
| Rule-of-thirds grid | 🟡 | CameraController, CameraPreview, CameraView, CameraSettings; real native APIs | Preserve; test on hardware. Fix recovery, motion availability and export denial UX. | P0 |
| Horizon leveling | 🟡 | CameraController, CameraPreview, CameraView, CameraSettings; real native APIs | Preserve; test on hardware. Fix recovery, motion availability and export denial UX. | P0 |
| High-resolution photo capture | 🟡 | CameraController, CameraPreview, CameraView, CameraSettings; real native APIs | Preserve; test on hardware. Fix recovery, motion availability and export denial UX. | P0 |
| RAW capture where supported | 🟡 | CameraController, CameraPreview, CameraView, CameraSettings; real native APIs | Preserve; test on hardware. Fix recovery, motion availability and export denial UX. | P0 |
| Camera and photo library permissions | 🟡 | CameraController, CameraPreview, CameraView, CameraSettings; real native APIs | Preserve; test on hardware. Fix recovery, motion availability and export denial UX. | P0 |
| Front/rear camera switching | ❌ | Rear camera only; automatic exposure only | Switch inputs with rollback; EV bias controls and capability limits. | P0 |
| Exposure adjustment | ❌ | Rear camera only; automatic exposure only | Switch inputs with rollback; EV bias controls and capability limits. | P0 |
| Aspect ratio switching (1:1, 4:3, 16:9) | 🟡 | PhotoAspect and PhotoRenderer support 3:4, 4:5, 1:1, 9:16 | Preserve current ratios; add actual landscape ratios; avoid integral crop exceeding bounds. | P0 |
| AI-powered composition analysis | 🟡 | Vision faces/pets/saliency and tracking, CompositionEngine, FramingPlanner | Real on-device detection with geometric heuristics; preserve. Verify mirroring and lens transitions. | P1 |
| Real-time composition suggestions | 🟡 | Vision faces/pets/saliency and tracking, CompositionEngine, FramingPlanner | Real on-device detection with geometric heuristics; preserve. Verify mirroring and lens transitions. | P1 |
| Subject detection and tracking | 🟡 | Vision faces/pets/saliency and tracking, CompositionEngine, FramingPlanner | Real on-device detection with geometric heuristics; preserve. Verify mirroring and lens transitions. | P1 |
| Framing guidance overlays | 🟡 | Vision faces/pets/saliency and tracking, CompositionEngine, FramingPlanner | Real on-device detection with geometric heuristics; preserve. Verify mirroring and lens transitions. | P1 |
| Suggestions to move left, right, up, down, closer, or farther | 🟡 | Directional guidance and automatic zoom; no distance advice | Add size-based closer/farther suggestions with limitations. | P1 |
| AI photography coach | 🟡 | Generic image classifier; templated SubjectAdvice and FieldGuide | Add measured exposure/detail coaching; label heuristics honestly, not a generative AI coach. | P2 |
| Automatic scene recognition | 🟡 | Generic image classifier; templated SubjectAdvice and FieldGuide | Add measured exposure/detail coaching; label heuristics honestly, not a generative AI coach. | P2 |
| Background clutter detection | ❌ | No image measurements or ratings | Measure background edge density, luminance/clipping, detail and geometric alignment. Report technical measures, not invented aesthetic scores. | P2 |
| Lighting suggestions | ❌ | No image measurements or ratings | Measure background edge density, luminance/clipping, detail and geometric alignment. Report technical measures, not invented aesthetic scores. | P2 |
| Composition and shot quality ratings | ❌ | No image measurements or ratings | Measure background edge density, luminance/clipping, detail and geometric alignment. Report technical measures, not invented aesthetic scores. | P2 |
| Smart shutter when the subject is correctly framed | ❌ | Manual shutter independent of guide | Opt-in, one capture per armed scan, foreground and readiness checks. | P2 |
| Reference image upload | ❌ | No import flow | Native PhotosPicker with bounded decoding, opacity slider and remove action. Local import only. | P1 |
| Transparent reference photo overlay | ❌ | No import flow | Native PhotosPicker with bounded decoding, opacity slider and remove action. Local import only. | P1 |
| Reference overlay opacity adjustment | ❌ | No import flow | Native PhotosPicker with bounded decoding, opacity slider and remove action. Local import only. | P1 |
| AI pose suggestions | ❌ | Faces only, no body pose analysis | Use detected body joints for limited posture suggestions; generative pose/style coaching requires a model/service. | P2 |
| Golden hour photography assistance | ❌ | No location or sun calculations | Opt-in location and offline solar elevation/window estimates with denial handling. | P3 |
| Low-light photography assistance | 🟡 | Camera low-light boost where supported | Measured lighting advice, no claim of reproducing Apple Night mode. | P2 |
| Burst photo capture | ❌ | One capture operation at a time | Bounded sequential 3/5-shot series; real measured detail/exposure ranking. Native high-speed burst not implied. | P3 |
| Best-shot selection | ❌ | One capture operation at a time | Bounded sequential 3/5-shot series; real measured detail/exposure ranking. Native high-speed burst not implied. | P3 |
| Film-style presets | ❌ | No editor/filter pipeline | Core Image editor, bounded preview, full-resolution derivative export retaining original; editor live preview. Preserve native camera preview. | P1 |
| Live filter previews where supported | ❌ | No editor/filter pipeline | Core Image editor, bounded preview, full-resolution derivative export retaining original; editor live preview. Preserve native camera preview. | P1 |
| Exposure, contrast, saturation, and warmth adjustments | ❌ | No editor/filter pipeline | Core Image editor, bounded preview, full-resolution derivative export retaining original; editor live preview. Preserve native camera preview. | P1 |
| Highlights and shadows | ❌ | No editor/filter pipeline | Core Image editor, bounded preview, full-resolution derivative export retaining original; editor live preview. Preserve native camera preview. | P1 |
| Grain effects | ❌ | No editor/filter pipeline | Core Image editor, bounded preview, full-resolution derivative export retaining original; editor live preview. Preserve native camera preview. | P1 |
| Vignette | ❌ | No editor/filter pipeline | Core Image editor, bounded preview, full-resolution derivative export retaining original; editor live preview. Preserve native camera preview. | P1 |
| Cropping and rotating | ❌ | No editor/filter pipeline | Core Image editor, bounded preview, full-resolution derivative export retaining original; editor live preview. Preserve native camera preview. | P1 |
| Before/after comparison | ❌ | No editor/filter pipeline | Core Image editor, bounded preview, full-resolution derivative export retaining original; editor live preview. Preserve native camera preview. | P1 |
| Custom filter recipes | ❌ | No editor/filter pipeline | Core Image editor, bounded preview, full-resolution derivative export retaining original; editor live preview. Preserve native camera preview. | P1 |
| Save and reuse presets | ❌ | No editor/filter pipeline | Core Image editor, bounded preview, full-resolution derivative export retaining original; editor live preview. Preserve native camera preview. | P1 |
| Export edited photos | ❌ | No editor/filter pipeline | Core Image editor, bounded preview, full-resolution derivative export retaining original; editor live preview. Preserve native camera preview. | P1 |
| View captured photos | 🟡 | PhotoLibrary, LibraryView, PhotoDetailView; real persistence and share/export | Preserve; improve denial recovery and paired-file cleanup. Device verification pending. | P0 |
| Save to device | 🟡 | PhotoLibrary, LibraryView, PhotoDetailView; real persistence and share/export | Preserve; improve denial recovery and paired-file cleanup. Device verification pending. | P0 |
| Favorites | 🟡 | PhotoLibrary, LibraryView, PhotoDetailView; real persistence and share/export | Preserve; improve denial recovery and paired-file cleanup. Device verification pending. | P0 |
| Share photos | 🟡 | PhotoLibrary, LibraryView, PhotoDetailView; real persistence and share/export | Preserve; improve denial recovery and paired-file cleanup. Device verification pending. | P0 |
| Delete photos | 🟡 | PhotoLibrary, LibraryView, PhotoDetailView; real persistence and share/export | Preserve; improve denial recovery and paired-file cleanup. Device verification pending. | P0 |
| Photo collections | ❌ | Gallery grid and detail scroll image only | Persist collections; zoomable full-screen viewer. | P2 |
| Full-screen image preview | ❌ | Gallery grid and detail scroll image only | Persist collections; zoomable full-screen viewer. | P2 |
| Photo metadata where available | 🟡 | Saved date, composition mode and pixel dimensions | Read EXIF camera, ISO, aperture, focal length and shutter from original. | P2 |
| Minimal, premium camera interface | 🟡 | Screenshot-based black/yellow/green SwiftUI layout and system haptics | Preserve identity; device/accessibility/compact-size verification. | P0 |
| Dark camera UI | 🟡 | Screenshot-based black/yellow/green SwiftUI layout and system haptics | Preserve identity; device/accessibility/compact-size verification. | P0 |
| Smooth transitions | 🟡 | Screenshot-based black/yellow/green SwiftUI layout and system haptics | Preserve identity; device/accessibility/compact-size verification. | P0 |
| Haptic feedback | 🟡 | Screenshot-based black/yellow/green SwiftUI layout and system haptics | Preserve identity; device/accessibility/compact-size verification. | P0 |
| Clear camera control icons | 🟡 | Screenshot-based black/yellow/green SwiftUI layout and system haptics | Preserve identity; device/accessibility/compact-size verification. | P0 |
| Responsive layouts | 🟡 | Screenshot-based black/yellow/green SwiftUI layout and system haptics | Preserve identity; device/accessibility/compact-size verification. | P0 |
| Safe-area support | 🟡 | Screenshot-based black/yellow/green SwiftUI layout and system haptics | Preserve identity; device/accessibility/compact-size verification. | P0 |
| Consistent visual design | 🟡 | Screenshot-based black/yellow/green SwiftUI layout and system haptics | Preserve identity; device/accessibility/compact-size verification. | P0 |
| Loading, empty, and error states | 🟡 | Library empty/loading/error, camera denial Settings link; camera checking mislabelled unavailable | Add actual checking spinner, retry, export Settings recovery, cancelled thumbnail protection. | P0 |
| Camera permission recovery screen | 🟡 | Library empty/loading/error, camera denial Settings link; camera checking mislabelled unavailable | Add actual checking spinner, retry, export Settings recovery, cancelled thumbnail protection. | P0 |
| Camera screen | 🟡 | Camera root; library sheet; Settings full-screen cover | Preserve navigation; centralize camera pause for new sheets. | P0 |
| Gallery screen | 🟡 | Camera root; library sheet; Settings full-screen cover | Preserve navigation; centralize camera pause for new sheets. | P0 |
| Settings screen | 🟡 | Camera root; library sheet; Settings full-screen cover | Preserve navigation; centralize camera pause for new sheets. | P0 |
| Explore / inspiration screen | ❌ | FieldGuide is educational content, not a full Explore screen | Reuse FieldGuide; add practical lessons/challenges and real editor navigation. | P1 |
| Photo editor | ❌ | FieldGuide is educational content, not a full Explore screen | Reuse FieldGuide; add practical lessons/challenges and real editor navigation. | P1 |
| Photography challenges | ❌ | None | Local practice tasks with capture counts; no fake AI certification. | P3 |

Implementation stages: P0 recovery/controls/mirroring and ratio correctness; P1 local reference overlay and Core Image editor; P2 measured coaching, opt-in shutter, organization and metadata; P3 bounded series/ranking, custom recipes and location-based planning. Reuse current controllers and components throughout. Add no dependencies. Camera live-filter rendering and generative coaching require a separate validated rendering/model architecture; do not degrade the native preview or disguise fixed text as AI.

## Post-implementation state (1.4)

The baseline table above is intentionally preserved. Front/rear switching, EV adjustment, requested aspect crops, recovery/loading improvements, reference import/opacity, Core Image editor/presets/recipes/export, collections/viewer/metadata, opt-in smart shutter, measured lighting/clutter/distance/pose assistance, technical ratings, sequential series/ranking, Explore/challenges and solar planning now have concrete source implementations. Native features remain 🟡 until a native build/device validation proves their behavior.

Camera live-filter previews, generative/aesthetic AI coaching/ratings, semantic scene understanding beyond generic frame classification, dedicated Night mode and native high-speed burst remain ❌ or 🟡 as described in IMPLEMENTATION-REPORT.md; they are not represented by fake controls. All physical validation is pending. Structural automated checks are recorded in VALIDATION.txt.
