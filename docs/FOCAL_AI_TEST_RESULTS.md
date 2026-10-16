# Focal AI test results

The focused implementation is complete. Static source and integration checks pass; the new Swift tests are registered in the iOS test target but were not executed on this Windows host. No physical-device behavior is claimed.

Investigation date: 2026-10-16. Source audit is pinned to upstream `61081f524fb6e10d66bfb24d0e8c30953a4a9b4f` (2.11.1). All 205 fetched files were verified against Git blob SHA-1; reconstructed Git tree exactly equals upstream `d1cd425f63a9c6dd837e3af364acc1afebad0aa3`. The local checkout has a synthetic snapshot commit because shell cloning is blocked by its proxy; remote changes must use the actual upstream commit as parent. No claim is made that the old recordings run this source.

Evidence consists of four supplied 512×1112 H.264 MP4s. No IPA, device trace, build identifiers, separate screenshots, touch overlay, outdoor footage or matched final photographs were supplied. File identities and durations are in [the manifest](evidence/framed-comparison/manifest.json). FFmpeg 8.0.1 from existing Krita installation decoded at 1 fps; overview images show every other sample. Labels are approximate output time bins (nearest decoded source frame); they are not exact transition or inference timestamps. Selected historical status transitions were also inspected at 4 fps. Audio was not transcribed. No tools were installed.

REA `binary_session(expected_package_version:"6.5.0")` succeeded with alignment `aligned`, 207 advertised MCP tools, and no active target. Ghidra and IDA are unconfigured; Hopper and Apple native helpers report unsupported Windows host. No unsupported Mach-O analysis was attempted. The supplied MP4s and Swift source do not have an applicable REA video/Swift-source analysis operation; video extraction and source audit use ordinary tools. No fabricated REA Evidence ID is assigned to manual visual observations. Previous session objdump probe failed with `ERR_REA_WINDOWS_NATIVE`; this investigation did not repeat it or repair configuration.

## Checks completed

- `scripts/validate_ai_frame_source.py --baseline bef7a47`: **PASS**, 329 checks, 135 Swift files, 641 registered XCTest functions. This checks source integration, project registration, protected-file hashes, assets, delimiters and repository structure. It explicitly does not compile or run Swift.
- `git diff --check`: **PASS**.
- `scripts/validate_structure.py`: **BLOCKED** before checks because PyYAML is not installed. No dependency was installed.
- `scripts/test_framing_portable.py`: **BLOCKED** before Swift execution because its temporary child directory could not be created under this Windows temporary-directory ACL. Swift/SwiftPM are absent from PATH as well. No tests were reported as executed.
- Native iOS build and all 641 XCTest functions: **NOT RUN**; Xcode/xcodebuild are unavailable on Windows. Codemagic has an `ios-check` workflow in `codemagic.yaml`; it has not been triggered.
- iPhone 16 Pro Max and Sony/Fujifilm camera acceptance: **NOT RUN**. No camera behavior is inferred from source-only fixture tests.

The 32 added regressions cover manual measured-layout READY gates; freshness, safety and bounded confirmation continuity; outdoor geometric alignment, challenger dwell and alternative locking; scene-current-frame retention; and tracking/admission cancellation. They are present in the existing Xcode test target. The baseline had 609 registered tests; the current source has 641. A count is not a pass result.

Protected hashes verified against the reconstructed upstream tree cover Sony camera, remote-control, Live View, photo capture policy, SubjectAutofocus, camera UI/preview, editor/gallery-adjacent protected sources. No Fujifilm-specific source was located, so its integration cannot be functionally verified from this repository. No external-camera zoom was added. Manual shutter ownership remains in the existing capture path.

## Remaining acceptance

Run Codemagic `ios-check` on this branch and inspect the XCTest result bundle. On iPhone, separately exercise: active AI through lens selection; pinch and zoom presets while tracking; motor behavior during and after the three-second manual-zoom grace; subject loss and return; already-good Thirds/Center/automatic frames; unsafe crop and motion rejection; and repeated alternatives. Capture time-correlated guidance logs and matched preview/still photos. Record separate outdoor clips for trails, repeating trunks, leaf detail, fog/backlight, reflections/water and small recognized subjects. The current code only uses the detections and pixel/edge evidence it can actually measure; forest-specific semantic labels remain unverified.
