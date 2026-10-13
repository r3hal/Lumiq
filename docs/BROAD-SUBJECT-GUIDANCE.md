# Focal 1.10 / build 13 — phone acquisition and broader subjects

The user reports that phone guidance stays at Finding your shot, while Sony mostly selects a person and is inconsistent. Source review found several concrete blockers:

- Phone acquisition was disabled whenever Core Motion failed the strict automatic-zoom hold test. Ordinary handheld motion could prevent all initial detections; Sony bypassed this phone-specific gate.
- Confident central people bypassed object recognition. A person could acquire quickly while desks/plants needed more samples, a high-confidence classifier result and strong color isolation.
- Only objectness proposals were classified. Weakly salient furniture and foliage had fewer opportunities; detailed leaves were penalized like anonymous background texture.
- A failure in a combined Vision stage could discard already detected candidates. Repeated expensive OCR/classification added latency; moderately changing candidate bounds restarted acquisition.
- A single tracking miss reset the footer's detection sequence even when the tracker was still recovering.

## Changes

Phone detection now tolerates ordinary movement and pauses new acquisition only during a rapid pan/strong shake, an actual lens ramp or the short manual-zoom cooldown. Focus, ready-state and automatic zoom retain the strict steady-hold requirement. A successfully framed phone subject remains selected until loss or explicit restart.

Both camera sources evaluate people/animals, objectness saliency, attention saliency and geometric rectangles. Person detection no longer exits before the object path. Only proposals mostly occupied by a detected person are skipped. Individual stage failures preserve successful stages. Crops use the existing bounded detail buffer; preview pixels and saved-image resolution are unchanged.

Moderate predictions (at least 0.25 with a competing-class margin) are accepted only for known photographic nouns in localized crops. They still need region support, real detail, spatial/temporal consistency and the configured relevance score. Whole-frame recognition keeps its older, stricter threshold. Desks, tables, chairs, sofas, plants and trees have stable aliases; probabilities are not summed and material/species are not guessed. Forest/room/wall scene labels do not create fabricated object bounds.

A real localized proposal with a specific supported noun can qualify without strong color contrast. Tree/plant texture has a smaller penalty; anonymous dense patterns retain theirs. Center position has more weight than detector-category priority. A sustained, well-supported central object can replace a peripheral person; ordinary small score changes cannot replace a healthy track. Manual subject selection retains priority.

Matching identity can accumulate across modest overlapping boundary jitter. A temporary tracking miss produces Keep the subject in view without publishing a stale box, ready state or blind zoom. Confirmed loss clears the subject normally.

Crop classification is limited to two eligible proposals per pass. Its soft time budget starts after proposal generation so a slower device still gets a first classification attempt. OCR is throttled and uses the fast recognizer; already read titles are processed even if a later classifier budget expires. Vision requests use the default accelerator-friendly processing preference. In-flight work and source/off/on cancellation still use the existing single-admission and generation gates. These choices require real-device latency, heat and frame-rate checks; a running Vision request is not forcibly timed out by the soft budget.

## Verification and retest

13 new XCTest functions cover detection versus zoom motion gates, rapid/invalid motion, localized versus whole-frame classifier thresholds, ambiguity, stable aliases, low-contrast desks/tables, required proposal evidence, textured trees, background rejection, boundary jitter/identity change, foreground switching dwell, subject-specific advice and brief tracking recovery. Total native test functions: 163.

Structural project/resource/workflow checks and numerical scoring spot checks pass. Native compilation, Vision/model output, all XCTest functions, performance and physical camera behavior remain unverified here: this Linux workspace has no Swift compiler, Xcode, Apple SDK or devices. The Xcode invocation returned command not found. Codemagic ios-sideload still runs the native tests before packaging the unsigned IPA.

Build main with ios-sideload and install over the existing AltStore app, then:

1. On the phone, enable guidance and slowly move across a desk, chair, plant or tree. A box/name should now acquire during normal movement. Hold steady to allow focus/zoom; try a rapid pan and subject loss, then restart. Verify that old boxes do not remain drawn.
2. Try low-contrast furniture, textured foliage, a person near an object, a central portrait, plain walls and clutter. Check actual labels/bounds, capture aspect and front-camera mirroring. Record subjects that still fail or are misidentified; Apple Vision does not guarantee universal recognition.
3. On Sony, point at furniture/vegetation without a person, then at an object with a peripheral person. Verify sustained acquisition and steady guidance; Sony still does not automatically zoom or use phone editing effects.
4. Compare preview frame rate and inference latency over several minutes, test off/on/source changes and background/foreground, and repeat existing Sony shutter/reconnect and phone RAW/editor checks. A7 III/A6100 behavior needs hardware retesting.
