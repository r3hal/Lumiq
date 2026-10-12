# Focal 1.5 / build 6 — automatic composition

Audited baseline: 2986db2. See [pre-change audit](AUTO-FRAMING-AUDIT.md).

## Result

The default viewfinder has no grid, crosshair, fixed framing line or level. A one-time migration switches older grid/level settings off; later explicit opt-in remains persistent. Internal manual thirds/center evaluation, corner selection and the optional level are retained.

Actual Vision human rectangles, faces, cats/dogs and salient regions feed one subject tracker. A tap selects a matching detected region or requests targeted acquisition, never an invented rectangle. The thin yellow box remains visible after automatic framing and during manual composition. It is damped, fades when lost and resets on a scene cut. Projection uses the existing aspect-fill/mirror model; zoom ramps reproject the selected region using the camera's achieved zoom, then resume tracking. Person detection prefers a body rectangle when available rather than cropping to a face. Models can still miss subjects or produce inaccurate boxes.

Bottom guidance uses detection confidence, actual position, occupancy, tilt, motion and framing state. Detection and actual zoom transitions are prompt; movement instructions require a persistent candidate. The ready state uses the composition engine's alignment dwell. No cloud model, random instruction or unverified detailed object description was added. Optional measured coaching and existing classifier capabilities remain.

Automatic zoom requires confident in-frame bounds, position within 4% normalized screen distance of center, reliable low device rotation/user acceleration and fresh motion data for the configured 0.5–2 second hold (default 0.9). Aggregate subject drift restarts the dwell. The zoom proposal preserves subject margins and final center tolerance, respects camera limits and the existing preview-detail/native-lens budget, and can occur at most once per scan. Pinch begins by cancelling the ramp and reading its achieved zoom, giving manual control until a new scan. Disabling automatic zoom retains manual tracking/guidance. Smart shutter stays opt-in and requires current readiness as well as confirmed guidance; phone movement prevents capture readiness.

The aperture-like top button now expands the bottom-of-preview strip: actual exposure mode, shutter, ISO and EV. Shutter/ISO are read-only; EV opens the existing native exposure-bias control. Fixed iPhone lens aperture is identified honestly. Unknown values show a dash. The three-dot menu contains Camera Source, camera switching and existing tools. The yellow footer button remains Scan; gallery and shutter remain in their existing positions.

Native high-resolution preview, separate 640-pixel Vision buffer, capture quality/RAW handling, original bytes, edits, reference overlay, library, series, practice and export flows are preserved. No filter or upscaling was added to claim improved camera quality. Real live-preview sharpness, lens transitions and low-light behavior require phone comparison.

Sony adds an isolated native ScalarWebAPI adapter with actual received JPEG live view and the same Vision pipeline. It does not use the iPhone preview or send Sony lens zoom commands. Controls depend on advertised capabilities. See [Sony integration and hardware checks](SONY-INTEGRATION.md).

## Validation

Passed in Linux: Swift grammar for 40 files (34 app / 6 tests), Xcode project parsing and references, scheme/plist/privacy/permission parsing, asset/font existence, local-network configuration, both free Codemagic workflow scripts, generator syntax/determinism and whitespace checks.

69 XCTest functions are registered, including 21 added checks for guidance/loss/debounce, motion, drift and hold gating, box smoothing, settings migration, Sony descriptor/host validation, fragmented live-view decoding, malformed packets and genuine telemetry. **None were executed here.** The Xcode build command was attempted and returned `xcodebuild: command not found`; there is no Swift compiler, Apple SDK, simulator or hardware in this workspace. Both cloud workflows run native tests; ios-sideload then archives and packages the unsigned IPA.

## Physical acceptance (pending)

1. Install over the existing AltStore app; confirm library/RAW/collections/recipes remain. Default grid/level off; explicitly enable them, relaunch and check persistence.
2. Rear/front people, cats/dogs, object, empty scene and multiple subjects: no phantom box, correct mirror/crop across every ratio, tap selection and tracking loss. Scan reacquires without switching cameras.
3. Offset subject: correct direction; noisy observations don't rapidly flip text. Center and hold: Detected → Hold steady → Adjusting framing → Great framing. Move/rotate the phone during hold: no zoom. Large/cropped/low-confidence subject: no unsafe zoom. Re-scan is required for another zoom.
4. Pinch during the ramp: cancel immediately, no jump to a stale factor, manual tracking continues. Turn auto zoom off; lens selection and pinch work normally. Smart shutter off by default; enabled shutter requires current steady readiness.
5. Expand the top exposure control: strip is at the preview bottom and does not block footer controls. Compare genuine shutter/ISO/EV to native readings; adjust EV, reset, switch lenses and reopen Settings. No adjustable iPhone aperture.
6. Shutter, gallery, settings, sheets, interruption, background/foreground, burst and Photos export. Check reference never enters saved captures. Compare native live preview and saved dimensions in the same light at 1× and each real lens; high digital zoom may reduce detail.
7. Independently run the Sony connection, stream, guidance, failure/recovery and capture checklist; record camera firmware, iOS, actual received resolution and advertised methods. No A7 III or A6100 functionality is labelled hardware-verified in this release.
