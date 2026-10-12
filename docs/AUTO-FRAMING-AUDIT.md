# Automatic framing audit — baseline 2986db2

This audit precedes code changes for the automatic framing request.

- Native iPhone camera, Vision face/pet/saliency tracking, measured coaching, lens ramps, exposure bias, white balance/focus, gallery, editing, practice, RAW and reference import already have real source implementations. Preserve them.
- Grid and level defaults are true, including persisted settings from older installs. The overlay also draws a center/thirds plus; these contradict the new default experience.
- Yellow boxes render only while FramingPhase.isPreparing. Completed/manual frames therefore lose the actual tracked box.
- Manual selection creates an arbitrary 18% rectangle even when no detection matches the tap. This must become focus plus targeted detection without a fabricated subject box.
- Bounding-box coordinates already pass through PreviewProjection and mirror/crop correctly, but box movement is unsmoothed and current point smoothing is separate.
- FramingPlanner checks center, adjacent rectangle changes and tilt, but no gyroscope/acceleration evidence. Finishing auto framing switches back to thirds by default, producing contradictory ready/adjustment behavior.
- Bottom messages can change every analyzed frame and use unconditional final templates even when composition is not actually ready.
- Pinch starts by writing the last published zoom, so cancelling a ramp can cause a small jump. Cancel on gesture begin, obtain the actual achieved zoom, then apply pinch scaling.
- The top aperture control is a generic Menu, not an expandable bottom settings strip. ISO and shutter telemetry are absent; exposure bias is real. Implement the requested layout rather than claiming it exists.
- No Sony controller, source selector, live-view transport or shared external frame entry point exists at this baseline.

Sony evidence: the official A7 III guide describes Ctrl w/ Smartphone and manual DIRECT Wi-Fi connection. Sony's Camera Remote Command page lists ILCE-7M3 but requires checking model-specific interface materials; a listed model is not proof of iOS wireless support. The developer's expo-sony-camera ScalarWebAPI implementation documents A7 III bench observations, capability discovery, descriptor addresses and JSON/live-view framing; its iOS wireless adapter is not implemented. Implement an original native capability-gated Scalar client, never a model-name assumption, and physically test separately. No proprietary SDK or external package will be bundled. PTP/IP/USB support remains a separate path if Scalar is absent. Never use iPhone video in Sony mode or send Sony lens-zoom commands.

Sources:
- https://helpguide.sony.net/ilc/1720/v1/en/contents/TP0001653182.html
- https://support.d-imaging.sony.co.jp/app/cameraremotecommand/en/index.html
- https://github.com/jongan69/expo-sony-camera/blob/main/docs/PROTOCOL_FINDINGS.md

Stages: clean defaults and real tracking boxes; stable measured guidance and motion-gated zoom; actual exposure strip; isolated capability-discovered Sony stream and shared Vision analysis; codec/geometry/state regression tests and native/device acceptance reporting. Xcode and physical devices are unavailable in this workspace; do not label them tested.
