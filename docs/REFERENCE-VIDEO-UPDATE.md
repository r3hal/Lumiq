# Focal 1.9 / build 12 — reference video update

Both supplied recordings were inspected frame by frame. Focal implements the visible workflow with its existing on-device Vision pipeline and independent Core Image recipes. It does not contain Framed's proprietary model or LUTs.

## Camera guidance

The longer recording shows a chair selected among people, a yellow subject boundary, a bottom instruction to move left and up, a centered hold, then real lens zoom and a compact green label. Focal now has:

- “Finding your shot…” while automatic phone framing searches without a confirmed subject.
- Both camera movement directions in one instruction, computed from the actual subject and target positions. Manual composition and Sony retain camera-appropriate instructions.
- “Centered — framing up…” only during a stable, centered hold; “Framing your shot…” during the actual zoom transition.
- The existing measured direction line, a target cross, a yellow acquisition box and a compact subject label after framing. A green label identifies the framing stage; it does not certify focus or artistic quality. The green ready state still requires the existing alignment/stability gates.
- Cancel while scanning and restart after framing. Restart invalidates pending inference before acquiring a new subject. Resuming after capture review starts a fresh scan.
- Foreground objects can now be considered when small or peripheral people are present. Central, substantial portraits retain the fast detector path; crop classification no longer skips a foreground region merely because it touches a person's box. Selection still requires specific identity, sustained confidence and measured separation.
- A chair-specific composition tip without guessing its material or whether it is empty.

Automatic framing continues to use the existing real lens ramp, crop margins, motion hold and device detail budget. Manual zoom cancels the automatic ramp. A new subject is not fabricated when evidence is insufficient. The native iPhone preview remains separate from the small analysis image; these editor effects never run over the live preview.

## Phone-only postcapture editing

The shorter recording shows RAW development followed by a black editor with Looks / Adjust / Effects / Frames, thumbnails, a ruler, grouped tools, Delete, Undo, Redo and yellow Save. The implementation includes:

| Area | Controls |
| --- | --- |
| Looks | Original, Cine, Honey, Sienna, Arc, Archive, Clean, Harbor, Dusk, Press, Album, Amber, Silver, Relic, Mono; existing Soft Film and Faded retained |
| Adjust | Exposure, Warmth, Contrast, Highlights, Shadows, Saturation, Tint, Vibrance, Fade, Curve, eight-band HSL, shadow/midtone/highlight Grading with balance, Whites, Blacks, RGB primary Calibration, Sharpness |
| Effects | Grain and size, Motion and direction, Light leak, Scratches, Halation, Dust, Glow, Fringe, Vignette |
| Frames | Original, Plain, White, Paper, Specs, Negative, Black, Instant; optional date stamp |
| Actions | Compare, crop, rotate, reset, saved recipes and recipe deletion, photo deletion, undo/redo, Save |

Curve is an S-curve strength control. The grading/calibration controls are grouped parameter rulers. Frames use independent borders and footer layouts, not scanned proprietary frame assets. Looks are independent tonal recipes, not exact copies of the reference app's output. Specs reads actual available EXIF; missing values are not invented. Date stamps use the capture date stored in the recipe.

“Review single shots” defaults on in Settings. Single phone captures are saved safely before the review opens; dismissing review retains that capture, while Delete removes it. Save replaces only that capture's derivative, keeping its camera JPEG, edit baseline, RAW and optional scan. Series continue to save directly. If automatic Photos export is on, review Save exports the finished derivative.

Supported retained RAW files are actually developed with CIRAWFilter. If RAW development cannot produce an image, editing falls back to the camera JPEG; no fake development timer is used. RAW capture and retention must be enabled to receive RAW. Edited gallery copies keep their recipe and original baseline, so reopening does not stack the same edits over an already edited JPEG. Preview rendering is bounded and debounced; full-resolution exports do not use preview thumbnails. Grain/scratch patterns use a stable seed.

Capture origin is recorded and persisted. Looks, adjustments, effects, frames and capture review are available for iPhone captures and the offline demo only. Sony captures are rejected by the review method as well as disabled in the library UI. Older captures are enabled only when their metadata identifies an iPhone; unknown older origins stay disabled. Sony live view, controls, shutter recovery, transfers, original storage and existing composition guidance remain available. Sony is not automatically zoomed or developed with the phone editor.

## Validation and retest

20 new XCTest functions cover decoding old recipes, new control persistence, normalization, parameter mappings, undo/redo branching, color math, all effect rendering, color-cube rendering, deterministic grain, frame dimensions, date stamps, source restrictions, one-entry review/original preservation, review preference persistence, grounded search/pan/hold text and foreground selection. The complete native target contains 150 test functions.

This Linux workspace has no Swift compiler, Apple SDK, Xcode, simulator or cameras. Project/resource/workflow and lexical delimiter checks pass; they do not establish Swift syntax validity, type checking, native rendering, model accuracy or device performance. Xcode invocation returned command not found. All 150 native tests remain unexecuted here. Codemagic ios-sideload still runs the native test target before archiving the unsigned IPA; tests were not bypassed.

Build latest main with Codemagic ios-sideload and install the IPA over the existing AltStore app. Check these on the iPhone:

1. Enable guidance; compare a centered chair/product among peripheral people against a central portrait. Verify actual names and boundaries, two-axis arrows, centering, one zoom, manual zoom cancellation, restart, subject loss, and low-light behavior.
2. Capture JPEG and RAW. Verify real development/fallback, crop orientation, every effect/adjustment, each frame, date/specs, undo/redo, Compare and full-resolution exported dimensions.
3. Save, close, reopen and edit again. Confirm the original and RAW variants are intact and previous effects are not applied twice. Test Delete, Photos permission denial and capture resume with and without guidance.
4. Connect the A7 III; confirm capture/live view still work and new editing/review controls remain unavailable for Sony files. Repeat the existing shutter/reconnect checks; A6100 compatibility remains separately unverified.
