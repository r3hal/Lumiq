# iPhone RAW/ProRAW — Focal 2.7.2 / build 30

The reported symptom is a disabled RAW/ProRAW switch, or a switch that does not remain available. This is an iPhone capture fix; Sony connectivity and transfer code are unchanged.

## Source defects and correction

The earlier session setup selected a preview `activeFormat` before querying RAW support, tried enabling ProRAW inside the uncommitted configuration, and read output capabilities from a main-queue closure. It never observed support changes. A virtual rear camera can consequently expose no Bayer formats while ProRAW remains disabled, leaving the switch grey even on suitable hardware. The old capture settings also silently requested only a processed image if RAW was requested but no format was available.

Apple documents that [setting `activeFormat` changes the session preset to `inputPriority`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activeformat). RAW support depends on the current device/configuration, and [ProRAW must be enabled before its format appears in the available-format list](https://developer.apple.com/documentation/avfoundation/capturing-photos-in-raw-and-apple-proraw-formats). This explains why checking the model name or merely enabling the UI switch would be insufficient. The precise state on the user's phone still needs device verification.

The controller now first commits the real `.photo` input/output configuration, enables ProRAW if supported, and reads actual RAW pixel formats. It then attempts the existing preview optimization. If that removes RAW or downgrades ProRAW support, it restores the system-negotiated `.photo` configuration with a compatible 30 fps target. Preview dimensions remain measured; neither preview scaling nor fake capability flags are used. The faster optimized preview remains when it preserves the photo configuration's RAW capability.

After final configuration/startup, support is published as an immutable value read on the camera queue. Output ProRAW-support and device active-format observations refresh this value. It is also refreshed before capture and after completion, including resume/reconfiguration and lens switches. Unsupported cameras display a short explanation; their disabled switch displays off while the saved RAW preference remains available for a supported camera. Existing UI placement is retained.

Capture settings use the advertised ProRAW pixel format preferentially, otherwise advertised Bayer RAW. Bayer RAW retains its JPEG companion and speed prioritization; ProRAW retains supported JPEG/HEIF and quality prioritization. Unsupported requested RAW now returns an explicit error instead of silently taking JPEG. A requested RAW capture cannot complete successfully without nonempty RAW data from AVFoundation's RAW delegate callback.

## Saved files

Existing delegate processing still obtains the DNG through `AVCapturePhoto.fileDataRepresentation()`. The local library, optional RAW development, RAW sharing and Photos export are preserved. Keep **Camera Settings → Keep RAW originals** on to retain the DNG; its existing opt-out remains respected. Focal's gallery normally displays the processed companion, which is not evidence that the DNG is missing. Cropped/edited processed images and full-sensor RAW originals continue to retain their existing distinction.

## Files

- `Focal/Camera/CameraController.swift`: committed capability negotiation, supported preview fallback, refreshed snapshots/KVO, actual capture selection and delivery validation.
- `Focal/Camera/PhotoCapturePolicy.swift`: shared format/codec/compatibility/delivery policy, supplied with actual AVFoundation formats.
- `Focal/Camera/CameraView.swift`, `Focal/App/CameraOptionsSheet.swift`: consistent effective RAW state, saved preference preservation and unsupported-camera explanation.
- `FocalTests/PhotoCapturePolicyTests.swift`, `scripts/test_framing_portable.py`: 14 policy cases executed alongside existing framing tests.
- Project generator/project, settings/evaluation version labels, README and validation record: build 30 and updated source/test counts.

## Verification

**Passed:** 211 portable XCTest cases on Swift 6.0.3/Linux, including 14 RAW policy cases and all previously passing scene/target/framing cases. The RAW fixtures verify selection of actual supplied pixel IDs, ProRAW preference, Bayer JPEG, supported/unsupported HEIF, preview capability preservation, no silent RAW fallback, required RAW delivery and changing capability snapshots. Placeholder test bytes exercise delivery presence only; no synthetic DNG is claimed as a real photo.

**Passed:** Swift grammar parsing for all 120 app/test Swift files. Structural checks cover 90 app/30 test sources, 451 registered XCTest functions, deterministic project generation, resources/configuration, frozen baselines, unchanged Sony source and user-only shutter wiring.

**Not available here:** Xcode, Apple API type checking/linking, real KVO/session negotiation, RAW encoding, actual DNG library/export verification and physical iPhone camera performance. The last supplied native result predates this fix. Run the complete updated suite/archive in Codemagic; portable policy tests do not validate the AVFoundation implementation on a device.

## Physical iPhone retest

1. Build latest `main` using `ios-sideload` and install the 2.7.2/build 30 IPA through AltStore. Open the rear camera and allow startup to finish.
2. Open the format/aspect or three-dot menu. On a supported rear camera, ProRAW/RAW must be enabled and remain selected after closing/reopening the menu. Restart Focal and check preference persistence.
3. Keep RAW originals on, press the shutter, and confirm the library has a nonempty `.dng` original that opens in a RAW-capable editor. Test both JPEG and HEIF companion preferences; Bayer RAW uses JPEG.
4. Change rear lenses/zoom stops, toggle AUTO/PRO, enter/exit review, background/resume and restart the app. Availability must match the actual connected camera. An unsupported front/lens combination must show off plus an explanation, and returning to a supported rear camera must restore the preference.
5. Test RAW off, normal photo capture, AI aiming/zoom followed by a user shutter press, cropped ratios and optional Photos export. Confirm preview quality/cadence and saved framing on the phone; high-resolution and virtual-camera combinations require device validation.
