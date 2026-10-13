Latest design/state/settings checks: [1.11 retest](TWELVE-SCREEN-DESIGN.md). Native compile, tests and visual/hardware verification remain pending.

Latest phone/Sony acquisition checks: [1.10 retest](BROAD-SUBJECT-GUIDANCE.md). Native execution and hardware retests remain pending.

Latest reference video/editor/guidance checks: [1.9 retest](REFERENCE-VIDEO-UPDATE.md). Native execution and hardware retests remain pending.

Latest capture/disconnect/OCR checks: [1.8 retest](SONY-CAPTURE-RECOGNITION.md). The user supplies Sony 5/40400 screenshot feedback; it does not validate the new correction.

# Native acceptance checks — Focal 1.8

Latest Sony/named guidance checks: [Sony retest](SONY-SUBJECT-GUIDANCE.md). The user reports working A7 III live view in 1.6.1, with poor quality/lag and missing guidance. The new correction remains untested on hardware.

None of these checks has been performed in this Linux workspace. Build ios-sideload on Codemagic: it runs 130 native XCTest tests before archive and IPA packaging. Install over the existing AltStore app to preserve the local library. Do not delete the app.

1. Open an existing library from 1.1–1.3: images, favorites, paired RAW/scans and originals remain. Relaunch after new captures, collection assignment and recipe saving.
2. On a fresh install, grant and deny Camera. Denial offers Settings; unavailable hardware offers demo/retry; checking shows progress. Test temporary interruptions and background/foreground return.
3. Compare live 1× preview with Apple Camera in the same scene. Record iPhone model, iOS, selected preview dimensions, available lenses, lighting and zoom. Compare real detail and noise, not only brightness. Inspect saved JPEG dimensions and original bytes in Photos/share.
4. Switch rear/front repeatedly. Preview and processed front photo should have matching mirroring. Tap left/right subjects, then test focus, exposure, ROI overlays and crop mapping for every ratio. Capture is disabled during input switching and automatic zoom.
5. Exercise EV slider at both bounds, reset, and lens changes. Flash/RAW should disable when unavailable. Test RAW+JPEG 3:4 and cropped export, retain/discard RAW, silent shutter support and regional sound rules.
6. In thirds/center, guide a subject from every edge; test manual corner selection and aspect changes. Test slight tilt, a missing/stale motion reading, looking down, missing frames and lost tracking. A missing level must not produce a ready state or auto shutter.
7. Scan → align → hold → smooth zoom. Test small/large/off-center faces, pets and other objects, lens transitions, zoom limits, pinch/cancel during ramp, switching/closing/backgrounding during ramp. Verify no pending auto request overrides a manual action. Subject classification can be wrong.
8. Enable smart shutter: exactly one capture/series per armed scan, no firing while sheets are open, permission blocked, inactive, switching, saving, searching, tilted or zooming. Manual capture consumes the arm. Try a new scan and a new tapped subject. Disable setting and confirm no auto capture.
9. Import a reference from local Photos/iCloud. Test success, cancel, load failure, opacity and removal. Camera must pause during import and resume after dismissal. Captures must not contain the overlay. Broad Photos-read access should not be requested.
10. Enable measured coach: use dark, clipped-bright, flat, textured and portrait scenes. Verify tips match measurements and only appear when joints/subject are detected. Try multiple people and pets, scene changes, guide off and unavailable motion. Technical/alignment metrics must not be described as aesthetic AI scores.
11. Capture 3/5-shot series including RAW where supported. Interrupt partway: earlier saved shots remain. Every shot remains accessible; best marker is based on the documented technical measure. This is sequential capture, not a high-speed burst.
12. In gallery, create a collection, assign/remove a photo, filter favorites/collections, open full screen, double-tap/pinch/pan, dismiss. Test failed/missing files and fast image variant changes.
13. Edit every preset and slider, shadows/highlights, grain/vignette, crop and repeated rotations. Compare original; save/delete/reuse a recipe. Save edited copy and verify dimensions, orientation, metadata and colors. Capture/RAW original files must not change. Test memory on a 48 MP image; previews are downsampled, exports are full resolution and sRGB.
14. Save/share selected Photo/Scan/Original and RAW. Grant/deny add-only Photos access; recover via Settings. Delete a photo and verify all associated files are removed, with no damage to remaining library entries.
15. Explore → guide/golden hour → back/Done → camera resumes. Start/end a practice and inspect capture count. Demo captures must not count. Practice counts do not judge artistic quality.
16. Golden hour: request location only on button tap, deny/allow it, enter manual coordinates, change date, check midnight/DST/polar cases. Estimates use phone timezone and no weather, terrain or refraction. Location must not be persisted or embedded into photos.
17. Check smaller iPhones, large text, safe areas, VoiceOver, loading/error states, low light and sustained battery/thermal performance. Coach and smart shutter are off by default.

For the 1.5 clean preview, measured automatic framing, exposure strip and independent Sony checks, use [AUTO-FRAMING-REPORT.md](AUTO-FRAMING-REPORT.md) and [SONY-INTEGRATION.md](SONY-INTEGRATION.md).

For the current AI toggle and all 14 requested subject-selection scenarios, follow [SUBJECT-SELECTION-REPORT.md](SUBJECT-SELECTION-REPORT.md), starting with the physical iPhone 16 Pro Max.

The reported motion/zoom and Sony invalid-JPEG failures require the targeted retest in [PREVIEW-SONY-FIX.md](PREVIEW-SONY-FIX.md).
