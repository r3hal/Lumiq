# Subject-selection audit — baseline 34809d6

- Footer scanButton always sets guide=true and calls findSubject; it cannot disable AI.
- CameraSettings.guide registers true and CameraController starts with guidanceEnabled=true.
- Off-state controller only exits before Vision when both guidance and coach are false. Persisted coach=true therefore keeps expensive analysis running with guidance off. Sony external frames decode before this gate.
- Automatic acquisition uses fixed person/face/pet/saliency priority buckets and then a size-based score. Salient objects have no photographic-relevance gate, so a room/background region is always chosen if any saliency observation exists.
- Existing Vision sequence tracking already retains a selected subject instead of scanning every frame; reuse it. One weak result currently immediately drops it. Manual tap uses real candidates, but fresh saliency candidates are not separately kept while tracking.
- Native focus is a separate preview callback and supported AVFoundation API. Preserve it regardless of AI state. Sony touch focus is already gated by advertised capability; no Sony lens zoom command exists.
- Automatic zoom already checks phone motion, margins and quality limits, but analysis pauses throughout the ramp, so subject loss cannot cancel it until the ramp ends. Replace this blind interval with tracking-only checks during zoom.
- CameraView was split into small builders in 1.5.1 after a cloud compiler timeout; keep those boundaries. The native rebuild result for that correction has not been supplied.

Plan: reuse the footer button and persisted guide setting; explicit disabled inference gate; shared, configurable weighted relevance scoring using actual detection/classification, saliency and sampled image evidence; sustained acquisition and challenger hysteresis; keep manual priority with real boundaries and a menu reset; scene-level landscape guidance without an object box; native regression/device checklist. Physical iPhone 16 Pro Max and Sony hardware are unavailable here.
