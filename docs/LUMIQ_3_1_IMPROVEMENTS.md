# Lumiq 3.1 (build 42): guidance presentation, aiming, power and lifecycle

Lumiq is the new name for Focal. The bundle identifier (`com.example.focal`), Xcode project/scheme/target names, file layout, library storage, Photos album and backup folders are unchanged, so an AltStore install updates in place and keeps its photos.

## What changed

### Guidance card no longer flickers
The physical-iPhone report recorded in `CLOUD_COMPOSITION_SCAN.md` (the card repeatedly cycling between *Finding your shot*, *Framing your shot* and *Aim your phone…*) is consistent with the card rendering each ~4 Hz analysis result directly. `GuidancePresentationStabilizer` (in `Focal/Camera/CameraGuidanceCard.swift`) now sits between the measured state and the card:

- an ordinary change of wording or state must persist for 0.3 s, and the line on screen stays for at least 0.7 s;
- honest state changes are never delayed: guidance off, active zoom, entering READY and leaving READY are shown at once, so the card cannot claim a ready frame after the camera stopped measuring one;
- a card appears immediately from hidden, but must persist before it disappears, so one low-confidence frame no longer blinks it out.

`GuidanceCardPresenter` drives it on the main thread and re-evaluates a pending change when its dwell expires. The director, READY gates, shutter and every measurement are unchanged; only presentation timing is.

### Aiming says which way and how far
During continuous framing the card previously named a single axis ("Aim your phone left"). `CompositionCue.aimInstruction` now uses the same aspect-scaled geometry as the overlay arrow and:

- names the second axis only when it is a real share of the error (≥ 45 % of the dominant axis and above the alignment tolerance), e.g. "Aim your phone up & left";
- says "Aim slightly …" once the subject is within 2.5× of the alignment tolerance;
- respects front-camera mirroring.

The dominant direction always equals the arrow's direction and the `GuidanceAction`.

### Battery and heat
Vision analysis cadence was thermal-aware only for iPhone frames. It is now also Low Power Mode aware (`PreviewAnalysisScheduler.powerAdjusted`: never faster than 0.4 s per analysis in Low Power Mode), and Sony live-view analysis now uses the same thermal and power cadence instead of a fixed 0.25 s.

### Camera interruption bug
Every capture-session interruption, including routine backgrounding, calls and Siri, raised a sticky "Close other camera apps" alert that was never cleared after the camera recovered. `CameraInterruptionPolicy` now explains only actionable interruptions (another app using the camera; thermal system pressure) and clears that alert automatically when the interruption ends.

### Capture feedback
"Saving…", "Capturing 2 of 5…" and "Saved to your library" were shown only inside the AI card, so they were invisible with AI Guidance off and replaced live guidance while saving. They now appear in a separate status badge regardless of the AI setting.

### Smaller fixes
- Settings footer showed a stale hard-coded "2.9.0"; it now reads the bundle version (3.1.0, build 42).
- "Send Feedback" pointed at a non-existent `focal-private` repository; it now opens this repository's issues.
- The field guide said there were "no uploads or cloud AI", which contradicted the optional Cloud Scan and Photo Backup; the text is now accurate.
- User-visible branding (home-screen name, permission prompts, camera wordmark, settings, guide) is Lumiq. Protected Library, Sony, Backup and Editing sources keep their existing wording in this change.

## Tests and guards
Seven new XCTest functions (743 total):
`CameraDesignStateTests` (3 presentation-stabilizer cases, also run by the Linux portable suite), `AutomaticGuidanceTests` (2 aiming cases), `PreviewFramePolicyTests` (Low Power cadence, also portable) and `ProfessionalCameraTests` (interruption policy).

The reviewed-source mechanism records each protected file this change touches (`docs/FOCAL_3_0_SOURCE_AUDIT.json`, `scripts/validate_backup.py`). `validate_structure.py`, `validate_backup.py` and `validate_focal3.py` pass locally. No Sony, Library or Backup source changed.

## Not verified here
This change was prepared on Windows without Xcode or a Swift toolchain. Native compilation, the XCTest suite and the unsigned archive run in GitHub Actions (`Focal 3 integration validation`, triggered by this push) and in Codemagic `ios-sideload`. Card timing (0.3 s dwell / 0.7 s minimum) should be confirmed on an iPhone; adjust `GuidancePresentationStabilizer.candidateDwell` and `minimumDisplay` if it feels slow.
