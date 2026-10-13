# Professional upgrade — pre-change audit

Baseline: Focal 1.12/build 15, source tree f206f2f7ca49b7988b276205c7a9f041364fa576. SwiftUI/AVFoundation/Vision/CoreMotion/CoreImage/ImageIO/Photos/URLSession; no third-party app dependencies. 201 XCTest functions registered. Existing Git history shows incremental camera, Sony, editor, recognition and composition improvements.

"Implemented" below describes inspected source, not a claim of device verification. Xcode/Apple SDK and physical iPhone/Sony hardware are unavailable in this workspace.

| Area | Baseline classification | Findings |
| --- | --- | --- |
| Launch/navigation | Implemented; device verification | App launches CameraView directly. Camera sheets/library/editor/reference/explore already exist. No recurring onboarding. |
| Camera permissions/session | Partial; device verification | Authorization, interruption, retry and high-resolution format selection exist. Runtime errors do not recover from media-services reset; a failed virtual-camera setup has no wide-camera fallback. |
| Preview/capture framing | Source defect | Standard immersive viewport crops more tightly than the saved 3:4 image. Orientation and front mirroring otherwise use real preview/capture connections. |
| Capture/RAW/gallery | Implemented; device verification | Quality-prioritized original JPEG/DNG, aspect derivative, local manifest, favorites/collections/export/share, phone-only editor and review. HEIF selection missing. Preserve files and manifest compatibility. |
| Zoom/focus/WB | Partial; device verification | Real pinch/native stops/ramp cancellation/continuous AF/automatic WB exist. Manual ISO/shutter/WB/focus interface missing. Tap/AI focus can re-enable auto settings, so manual locks need explicit protection. |
| Exposure/aperture | Partial | Real read-only ISO/shutter/mode/aperture and writable EV. Aperture is correctly informational. No explicit AUTO/PRO control mode. |
| Intelligence | Implemented; device verification | Real face/person/pet/saliency/rectangle/classification/OCR candidates, temporal selection/tracking, actual projection, source/generation gates, category-neutral merit and composition comparisons. No photography intent. |
| Automatic zoom | Implemented; device verification | Measured hold, confidence, retention/detail/lens bounds, one ramp per scan; manual cancellation. Preserve this coordinator. |
| Precision/AutoTune | Missing | Technical luminance/detail measures exist, but no independent histogram/zebra/peaking pipeline or settings recommendation engine. |
| Insights/Compare | Partial / missing | PhotoMeasurements and metadata exist in detail screen; dedicated captured-image subject/composition analysis and two-image comparison missing. |
| Sony | Partial; actual A7 III verification | Local descriptor identification, advertised JSON controls, genuine JPEG live view, frame delivery, shared AI, capture/focus and reconnect code exist. Manually entered address; SSDP discovery missing. PTP/IP is explicitly unimplemented; never substitute phone/demo frames. A6100 remains planned. |
| Visual identity | Needs change | Existing pure black/yellow/green camera hierarchy is based on competitor screenshots. Replace surfaces, wordmark, status/navigation, AI icon and guidance wording with original Focal identity. |

Preservation constraints: keep existing providers/session/capture/gallery/editor/Sony protocol, no fake UI values or placeholder controls, no forced subject for empty scenes, manual state independent of AI, independent overlay switches, no undisclosed manual-control overrides. Build/test and hardware limitations will be recorded at each stage and in the final report.
