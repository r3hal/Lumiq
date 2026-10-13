# Intelligence audit — build 18 baseline

Baseline commit: beaced8242f97531bb54812850c0cf8a11922632. Frozen developer-only guidance/planner sources are stored before modifying the algorithms.

- Vision requests: human/face rectangles, cat/dog recognition, objectness/attention saliency, rectangles, localized/global classification, printed text, tracking; conditional human pose exists only in Coach. No bundled Core ML weights or external service.
- Bounds >0.85 on either dimension trigger Step back even with comfortable remaining margins. A box touching a visible crop is conflated with actual anatomical clipping; pose/face visibility is not assessed.
- Class-name tips can appear after readiness regardless of pose/intent, e.g. get down to eye level, rim/petal isolation. These are hardcoded text, not measured scene facts.
- Global outside-subject edge density is not semantic distraction evidence; bedding, fur, architectural detail and noise can be mistaken for clutter.
- Crop/layout scores reward predefined techniques. There is no explicit keep-current-frame candidate, minimum improvement over current fitness or calibrated acceptable-position region.
- Hold/ramp freeze and manual pinch protections exist, but advice memory only tracks message dwell and previous box velocity. It does not assess resulting issue changes, regressions or repeat action history.
- Intent filters/ranking bonuses exist but most guidance size/position thresholds are universal.
- Coordinate projection supports aspect-fill and front mirroring; raw boxes and shared tolerance were added in build 18. These components should be reused, not rebuilt.
- Offline Insights independently repeats size/clutter suggestions, diverging from live guidance.
- Bounded frame copies/serial Vision scheduling and stale guidance generations already protect rendering. These should remain.

These findings come from source inspection, not reproduced physical-camera runs. Baseline XCTest cases record the large-but-contained cat and forced layout behavior. Xcode is unavailable in this Linux workspace, so native executions and real-image accuracy remain pending.

The build 18 score additionally subtracts up to 0.22 for texture even on recognized people/pets. A high-confidence cat with weak saliency/isolation can therefore miss the 0.68 selection threshold on a textured bed. The semantic texture penalty is now 0.03; anonymous object proposals retain stricter texture evidence. The old scoring method is separately frozen for comparison.
