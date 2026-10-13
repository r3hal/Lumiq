# Focal 1.7 / build 10 — Sony delivery and named subject guidance

## Evidence and limits

The user confirms A7 III live view works in 1.6.1, but reports poor quality, lag and no useful automatic guidance. This confirms their previous connection succeeds; it does not verify this new build. The workspace has no Apple toolchain or cameras.

Code inspection found three specific preview issues: Sony delivery was capped to 10 fps, every decoded frame republished the entire SwiftUI camera view, and a landscape stream was enlarged/cropped into the default portrait iPhone viewfinder. Analysis decoded the same JPEG again. The relevance policy also demanded strong pixel separation even from confident people/pets and ordinary recognized products; unclassified saliency regions could acquire the generic name Subject. The overlay showed a box but no composition target or pan line.

## Sony preview

- Serial network parsing hands only the newest waiting batch to a separate decoder. Decode and main-thread presentation each have a bounded, replaceable mailbox; no FIFO replay, no artificial 10 fps limit. Work over 0.5 seconds old is dropped. Disconnect closes both mailboxes and connection generations still reject stale publications.
- Decode native image pixels once, including EXIF orientation at the original dimensions. ImageIO must finish decoding real data; malformed images are counted and skipped. Native stream images remain limited to 16 megapixels for bounded memory. No invented image detail or iPhone fallback.
- Present pixels directly through a UIKit layer, without publishing the whole SwiftUI camera hierarchy every frame. State, dimensions and diagnostics update only on changes or approximately once a second.
- Feed the already decoded CGImage to the separate Vision queue. Admit at most one analysis frame and four per second; reuse a 1280-pixel analysis surface and a 640-pixel Vision surface. Neither replaces the preview pixels or captured JPEG.
- Query available/supported live-view sizes only if Sony advertises the API. Select L, then M, then S from the actual advertised list. An unsupported/failed size change keeps the camera default. The setting is a request, not proof of higher resolution. Diagnostics show received dimensions and incoming/decoded fps.
- Sony opens in Camera frame: native aspect, complete received image. Portrait/square/wide crops remain selectable. The aspect menu can extend outside a short landscape preview. Overlay, tap focus and analysis all use the same active preview aspect. In Camera frame, captures retain the original transferred JPEG bytes without the iPhone portrait crop. Deliberate crops preserve an original as before.

Wireless resolution/compression/fps, signal strength and camera exposure/focus remain camera limits. A 640×424 wireless JPEG cannot become a sensor-resolution photograph. This update removes app-side loss/delay; smoother or sharper hardware results are still unmeasured. Original capture quality is independent of the low-resolution wireless preview.

## Automatic subjects and direction

Selecting Sony turns on AI Guidance, resets automatic selection and starts thirds composition. The footer toggle still turns it off, stops analysis and clears cues. Reconnecting does not override a manual Off. iPhone keeps its existing opt-in toggle and automatic native zoom behavior; Sony lens zoom remains on the camera.

People/faces/cats/dogs use actual semantic detector boundaries. Confident semantic detections avoid extra product classifiers. Other candidates use objectness saliency, up to three actual region crops with context, and Vision classification. Specific names require at least 0.6 classification confidence, sufficient margin over a conflicting second prediction, valid measured boundaries, relevance and repeated acquisition. Broad object/structure/room/equipment labels cannot become automatic named subjects. Crop classification is not a universal object detector; its boundaries and names can be wrong. No brand, RGB, material or intended subject is invented when Vision cannot identify it.

People/pets no longer require a contrasting background. Named products can pass with lower contrast, while flat rooms, unknown regions, landscapes-as-object-boxes and dense texture remain excluded. Identity as well as overlapping bounds must persist through acquisition. Manual taps still select an actual observed boundary; unknown manual subjects have no generic floating label. Landscape recognition gives scene-level foreground guidance without inventing a subject box.

A target ring, dashed tether and camera-pan arrow appear only for a current confident subject. Pan direction is the opposite of the subject's desired movement on the screen. Footer examples: Keyboard detected; Pan right · place the keyboard on the mark; Great framing · Isolate the keys; catch the light. Named advice is a local composition suggestion, not proof of light/pose/optical sharpness. Measured coach remains a separate optional setting. Loss clears the line; readiness requires existing dwell, position and motion rules. Sony cannot borrow the phone's roll sensor to claim the camera is level.

## Checks and required retest

Twelve new native XCTest functions cover mailbox replacement/closing, advertised-size gates, real JPEG native dimensions and EXIF rotation, ambiguous/generic labels, sustained identity, low-contrast relevance, pan signs in portrait/landscape, no line for missing/uncertain bounds, and named debounced guidance. The target has 111 tests. None executed here. Structural checks are not native Swift type checking or device/performance verification; Codemagic ios-sideload still runs tests before packaging.

1. Rebuild main with ios-sideload and install over Focal in AltStore; preserve the library.
2. A7 III: select Sony, connect, verify Camera frame shows the whole image and the AI button is on. Compare the same scene/zoom with the camera's own remote preview. Check Settings for actual dimensions, size request and incoming/decoded fps. Test a pan with AI Off and On and continuous streaming for thermal/memory behavior.
3. Hold on a person/pet, then a keyboard/mug/plant. A repeated confident name should acquire automatically; no tap is required. Check line/text signs by panning each way, thirds corner changes, Center mode, subject loss and acquisition of a different scene. Ambiguous/empty rooms must not get object/structure labels.
4. Choose a portrait crop then Camera frame. Check image/ROI/target/tap-focus alignment, menu hit testing and capture dimensions. Camera frame capture should retain the whole Sony JPEG; a chosen crop should match its preview and retain the original. Repeat with EXIF portrait orientation.
5. Toggle AI Off during acquisition; reconnect/foreground/background/capture/disconnect/switch to iPhone. No old pixels/cues must leak across connections. Repeat iPhone manual/automatic zoom, focus, capture/RAW and guidance toggle checks. A6100 needs its own test.
