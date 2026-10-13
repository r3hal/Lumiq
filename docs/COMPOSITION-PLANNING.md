# Focal 1.12 / build 15 — composition planning

Previously, automatic phone framing forced a detected subject to the center. The new planner compares visible framing options and feeds the selected target and technique into the existing direction overlay, bottom guidance, hold state and zoom planner. AVFoundation, Vision, Core Motion and the shared Sony frame pipeline are reused.

## Research

Reviewed on 2026-10-13:

- [Nikon: Composition guidelines](https://www.nikonusa.com/learn-and-explore/c/tips-and-techniques/5-easy-composition-guidelines): thirds, horizon placement, looking room, leading lines and repetition offer alternatives; reflections can justify centered horizons.
- [Nikon: Essential composition techniques](https://www.nikon.co.uk/en_GB/learn-and-explore/magazine/tips-and-tricks/essential-composition-techniques): balance concerns included and excluded elements, rather than symmetry alone.
- [Adobe: Symmetry and balance](https://lightroom.adobe.com/academy/principles/composition/symmetry): space and secondary elements can balance the subject. Focal compares actual pixels and separate detected regions.
- [Adobe: Leading lines](https://lightroom.adobe.com/academy/principles/composition/leading-lines): line arrangement should direct attention. Focal checks continuous environmental edges and their relationship to the subject.
- [Adobe: Fill the frame](https://lightroom.adobe.com/academy/principles/composition/fill-the-frame): tightening is one choice; viewpoint and layers can be more useful. Zoom is restricted to supported centered crops.
- [Adobe: Juxtaposition](https://lightroom.adobe.com/academy/principles/composition/explore-juxtaposition): contextual meaning needs photographic intent. This remains advice rather than a claimed semantic inference.
- [Nikon: Composition grids](https://www.nikon.co.uk/en_GB/learn-and-explore/magazine/tips-and-tricks/7-composition-grids-to-try-for-better-food-photography): golden geometry offers alternative placement. Golden-ratio points are not proof of a spiral.
- [Zeng et al., CVPR 2019: Reliable and Efficient Image Cropping](https://arxiv.org/abs/1904.04441): bounded crop comparison should preserve content and aspect ratio. Focal uses that approach, **not the paper's trained network, weights, benchmark scores or reported performance**.

Composition is open-ended. The guide covers 22 common techniques, rather than claiming every artistic arrangement or a globally greatest photograph.

## Evidence and guidance

| Technique | Evidence / behavior |
| --- | --- |
| Thirds, centered, golden ratio | Real boundaries, safe margins and placement alternatives. Manual Center/Thirds override Automatic. |
| Symmetry | Mirrored RGB similarity with sufficient pixel variance. A uniform wall cannot qualify. |
| Negative space | Calm visible side regions measured by edge density and variance; preserve space without zoom. |
| Fill the frame | Bounded centered crops, subject occupancy, clipping and retained boundaries. |
| Leading lines | Continuous long environmental edges with a segment close to the selected subject. |
| Diagonals | Observed long oblique edges; camera leveling remains separate. |
| Frame within a frame | Fresh Vision rectangle enclosing the subject with sufficient additional area. Shape identity is not invented. |
| Visual balance | Separate detected subjects with area/confidence weight on both sides. |
| Triangles | Three deduplicated regions whose centers enclose sufficient triangle area. |
| Rule of odds | An observed group of three or five; never zoom one out. |
| Patterns/repetition | Periodic row/column structure with contrast and a dissimilar half-period. Random texture or flatness alone cannot qualify. |
| Layers | Separate elements at different vertical positions and apparent sizes. This is 2D context, not measured depth. |
| Simplicity | Background edges and crop retention; existing clutter/lighting advice remains active. |
| Color/light contrast | Measured subject/background RGB separation and clipping penalties. |
| Horizon placement | Fresh landscape classification and a long horizontal boundary; camera-direction advice without an invented object box. The boundary is a candidate horizon, not semantic sky segmentation. |
| Reflections, looking/movement room, curves/spirals, perspective, juxtaposition | Photography-guide advice requiring visual judgment; no fabricated gaze, depth, reflection, curve or story detector. |

Sixteen subject-based layout families enter comparison. Landscape horizon guidance is a separate measured path. Five techniques remain visual-judgment advice.

## Planning and controls

Existing detectors still propose real named people, pets, furniture, plants, products and landmarks. Generic background/object labels remain rejected. Selection now receives a small category-neutral merit term for isolation, detail, usable size and placement; manual tap intent remains dominant.

At most once per 0.8 seconds, a 48 × 24–80 sample of actual viewport pixels accounts for aspect-fill cropping and front-camera mirroring. It runs on the existing analysis queue and does not change native preview/photo resolution. Layout eligibility requires its evidence. Candidates compare the full visible frame and centered crops at 1×, 1.15×, 1.35× and 1.6× where the device budget permits. Each evaluated crop stays inside the observed view and retains the subject with a margin, relevant detected context and enclosing frames.

Ranking considers evidence, subject size, placement, background edges, clipping and crop cost. Scores are relative heuristics, **not aesthetic probabilities**. The view model retains three alternatives. The chosen side/corner stays stable while panning; a stronger supported layout needs a margin and 1.6 seconds of persistence. Subject loss/identity changes, layout/source/geometry changes and rescanning reset the relevant state. Short recovery hides the box rather than treating the old detection as current.

Both the direction overlay and text use the selected target. The card shows its technique, and saved guided photos record it. The app scores known pixels; a suggested pan changes the view and gets analyzed again. It does not score unseen scenery as if it already knew what panning would reveal. Existing throttled detection refreshes context while retaining the framed subject; this adds analysis work after settling and requires physical performance measurement.

- AI off still runs no subject/planning inference or automatic zoom; ordinary autofocus remains active.
- Automatic is the initial composition layout. Center/Thirds and thirds-corner changes are explicit overrides.
- AI Settings adds persistent Composition Planning, default on independently of AI Guidance, which still defaults off. With planning off, Automatic uses centered guidance.
- Only positively evaluated **centered** crops drive phone zoom. Off-center layouts, groups, enclosing frames and context layouts settle without a sensor-centered zoom that destroys placement.
- Actual ramps remain bounded by the evaluated scale, whole-subject fit, hardware limits and existing preview-detail/native-lens budget. Motion-verified hold is required; one zoom per armed scan and immediate pinch/lens cancellation remain.
- Sony uses the same pipeline with real received preview frames. No Sony lens zoom, exposure controls, fake connection, example photography or unsupported control was added.

## Verification

25 new native XCTest functions cover blank/invalid/uncertain subjects, object/person parity, symmetry/repetition, line relationships, enclosing frames, group retention/deduplication, crop bounds/budget, stale evidence, target stability/loss/zoom freezing, safe margins, off-center zoom prevention, scale caps, identity requirements, mirrored aspect-fill geometry, challenger dwell, guidance directions, manual overrides and conditional landscape advice. Existing settings tests now cover the new preference. Total: **201 XCTest functions**.

Structural checks passed: lexical delimiters in 69 Swift files, 53 app + 16 test registrations, deterministic project generation, plists/shared scheme/assets/fonts, cloud YAML/shell syntax and whitespace. These are not Swift grammar/type checks.

Xcode simulator build and test were attempted; both exited 127 because `xcodebuild` is unavailable here. No native XCTest functions ran. Codemagic `ios-sideload` still runs native tests before IPA archiving. Compilation, rendering and physical performance remain pending.

Retest on iPhone and A7 III:

1. People, pets, tree/flower, desk/chair, printed product and empty wall; tap selection, automatic switching and AI off/on.
2. Calm side space, mirrored architecture, converging path, diagonal edge, enclosing shape, groups and repeated bands; inspect the actual recommendation/direction.
3. Pan across a subject: retained corner, persistent layout changes, no readiness during tilt/motion/loss/ramp.
4. Centered crop only, detail/native-lens caps, no cut subject/group/frame, immediate pinch cancellation and no rearm after sheet dismissal.
5. Sony full received aspect, meaningful objects beyond people, no automatic lens zoom; capture/focus/disconnection regressions.
6. Native preview FPS, inference cadence, memory/heat during movement, zoom and settled guidance; capture/RAW/white balance/gallery/editor/permissions and iPhone 16 Pro Max UI regression checks.

Build latest `main` with `ios-sideload` and install its unsigned IPA over Focal using AltStore Classic to preserve the local library.
