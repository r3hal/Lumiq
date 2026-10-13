# Focal 2.1 / build 18

Incremental changes to the existing camera session, Sony adapter, precision sampler and detector/tracker/planner. Build 17's SwiftUI Section compilation fix is retained. There are no new packages, models, backends or entitlements.

## Camera and readable advice

- Sony address starts with `192.168.122.1`. A previously verified valid saved host takes precedence; blank/invalid saved values fall back to the default. Prefilling does not imply a connection. The phone still needs the camera's DIRECT Wi-Fi and Local Network permission.
- AutoTune advice remains visible for at least 3.5 seconds while preview measurements arrive. Competing advice needs 0.7 seconds of repeated support before replacing it. Same-kind measurements refresh timestamps without restarting the minimum display period. Stopping, source/lens/options changes and clock gaps reset presentation.
- A retained exposure recommendation is not actionable unless it matches current measured recommendations and passes the existing AUTO/source/manual-exposure/pause/capture/freshness guards. PRO controls retain priority.
- LENS stays outside the horizontally scrolling parameter strip. It offers a checked active hardware choice and Automatic lenses. Session rebuilds retain PRO mode, clear old capability readouts, serialize switches and restore the previous selection on failure. An explicit lens choice cancels AI zoom until guidance is rearmed, while retaining subject guidance. No lens controls are offered for the Sony adapter.

## Guidance, framing and zoom

Optional background advice no longer traps an aligned frame in an adjustment state. An aligned stable shot reports composition readiness; important measured light warnings can remain in the instruction. This reports placement, not perfect exposure or aesthetic quality. Physical motion/loss/tilt/edge clipping still block readiness.

The planner, direction overlay and bottom instructions use the same raw-boundary tolerance. The subject box remains visually smoothed independently. The chosen layout is frozen during hold, ramp and completed framing to avoid immediately asking for a different composition after the user follows a target.

Automatic mode now evaluates crop scales for centered, fill-frame, simplicity, contrast, thirds and golden-ratio layouts. For off-center destination `d` and scale `s`, the phone is first guided to `0.5 + (d - 0.5) / s`. Sensor-centered zoom then moves the actual subject onto `d`. This is a real lens ramp, not a digital pan or cropped substitute preview.

The subject must fit in both the observed crop and at its destination with margins. A planned ramp is rejected if its pre-zoom geometry, final placement or scale is unsupported. Scales come from the measured detail budget and actual native lens stops, with a maximum relative crop of 3 for Auto/Pet/Product and 1.6 for Portrait. Context/group/enclosing-frame/negative-space layouts retain context; Architecture/Landscape do not auto-zoom. Manual Thirds remains a manual composition override. Existing one-ramp-per-scan and immediate pinch cancellation remain.

Enable AI Guidance, Automatic Zoom, Subject Tracking and Composition Planning for this automatic flow. The Sony feed uses the same measured subject/layout guidance; its lens zoom remains manual on the camera.

## Broader subjects with bounded analysis

The familiar noun list is no longer an eligibility gate for all moderate localized predictions. Other specific labels in the installed Vision classifier can qualify at 0.35 confidence with a competing-class margin, actual localized boundaries, prominence, detail, size and repeated selection evidence. Familiar aliases retain the previous 0.25 sensitivity. High-confidence specific labels were already eligible; weak/ambiguous/generic/background predictions still do not produce fabricated subjects.

The crop scanner always revisits the strongest real proposal and rotates the second crop among up to four measured regions. It keeps two classifications per pass. A four-entry cache expires after 2.5 seconds, requires current matching boundaries and is invalidated by a contradictory classification or a reset. Native person/face/cat/dog requests and printed-subject paths are preserved. No promise of recognizing every item, distinguishing every species or finding an objectively greatest photograph is made.

## Verification

22 new native XCTest regressions cover readable advice, stale exposure guards, default/saved Sony addresses, PRO transition state, broader identity/selection evidence, crop scheduling/cache expiry, off-center projection, unsupported/cut-off crops, quality scales, manual cancellation, ready/background advice and shared alignment. Two existing expectations were updated for the intended off-center zoom and aligned-light-warning behavior. Total: 257 XCTest functions in 18 files.

Source/resource/lexical checks run in Linux. Native simulator build/test is attempted, but this environment has no Xcode/Apple SDK. No native test or hardware success is claimed. Codemagic still runs XCTest before archive/IPA packaging.

Device checks after a successful native build:

1. Confirm the prefilled Sony address; test another saved host and return to real Sony live view.
2. Enable AutoTune; briefly pan into darkness/movement, then stop. Read the card for at least 3.5 seconds; stale EV actions must disable.
3. In PRO, switch Wide → Ultra wide → Telephoto → Automatic lenses repeatedly where available. PRO and manual-control priority must remain; supported capability readouts must update.
4. Enable automatic guidance/tracking/planning and frame a named object. Follow the line, hold, verify the real ramp places it on the final target without cropping edges; the line must disappear when aligned.
5. Repeat at each aspect and front/rear device. Pinch during hold/ramp and verify automatic zoom stops immediately until rearmed.
6. Test furniture, instruments, products, plants, wildlife and scenes against generic walls/weak predictions. Recognition failures remain possible; never accept a cached box without a real current boundary.
7. Verify RAW/HEIF/JPEG capture, gallery, manual exposure/focus, Sony shutter/recovery, frame cadence and device heat.
