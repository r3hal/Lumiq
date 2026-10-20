# Test the main Focal app on iPhone from Windows

Updated 2026-10-20. Main already contains the cloud composition experiment and Focal 3 reliability integration. Use the same Focal target/bundle, not an evaluation app.

## Live Gemini scan

1. In Codemagic, open r3hal/focal-private and start a new build from branch **main**. Select **ios-cloud-personal / Focal - PRIVATE Debug Cloud Scan (SSH download only)** and enable **SSH/VNC access** before starting.
2. Keep the existing app-scoped focal_cloud_personal environment group with GEMINI_API_KEY marked Secret. Never paste the key into chat, source, GitHub, or a plain YAML variable. The configured model remains gemini-3.8-flash; no automatic substitution is made.
3. The build checks this project's model metadata and makes one bounded structured text request. If it fails, read only the safe stage/HTTP/category line and resolve the account/request issue privately. CI fixtures do not prove real Google availability. Do not weaken restrictions or bypass a failed check.
4. After PRIVATE DEBUG IPA READY, use Codemagic's displayed SSH details and the printed SCP source to download the IPA to Windows within 15 minutes. Follow the exact PowerShell SCP and SHA-256 acknowledgement procedure in [PERSONAL_CLOUD_SCAN_WINDOWS.md](PERSONAL_CLOUD_SCAN_WINDOWS.md). The workflow publishes no IPA artifact. Do not look for a private IPA in Artifacts or reroute it to another upload service.
5. Install the downloaded IPA using the existing AltStore Classic/AltServer flow. AltStore signs it with your own Apple Account; no paid Developer membership is needed by the archive workflow. Actual signing/launch still requires the device/account checks in that flow.
6. Open Focal with the iPhone source, Automatic composition and AI Guide enabled. Long-press **AI Guide**, select **Cloud AI Scan (Experimental)**, acknowledge the one-frame Google disclosure, then press **Send one frame to Google**. Opening the sheet alone sends no image. Keep the subject and scene reasonably steady while the response is matched locally.
7. Return to the camera when a plan is locked. READY, tracking, AF, zoom safety and capture remain local. Press the shutter yourself. An unavailable or mismatched scan must return to local guidance.

The private Debug IPA includes the key and is sensitive even after installation. Keep it private, acknowledge download promptly, and remove unnecessary local copies. Release and ios-debug-sideload contain no developer key; they are appropriate for ordinary camera tests but do not enable direct Gemini scans. A distributed cloud feature requires a deployed authenticated proxy, which is not configured by this change.

## Device acceptance checklist

- Run a scan of one clearly tracked subject; verify one upload, a stable plan, fresh local READY and user-only capture.
- Rescan, cancel during preparation/network activity, dismiss the sheet, disable AI Guide and change source/mode. Old results must not install a plan or overwrite newer guidance.
- Disconnect the internet or hit a provider error. The preview, local Guide and manual camera controls must keep working. Inspect no sensitive provider bodies or credentials.
- Pinch/manual zoom while guiding and after READY. Keep the selected composition, motor grace and manual priority; verify that focus does not hunt or depend on Auto Zoom.
- Move away from the subject, cover the lens and reacquire. READY must expire, recovery must show no unsupported arrows, and stale scene evidence must not leave a permanent READY state.
- Verify manual Thirds completion with Auto Zoom off; then test landscapes and forest scenes without treating model confidence as a measured composition score.
- Test camera interruptions/resume and lens changes on the iPhone 16 Pro Max. Validate Sony A7 III connection/Live View/controls separately; Cloud Scan remains disabled for the Sony source.
- Verify photo saving, gallery, editor and film effects. This task changes no backup, Drive enrollment or photo-upload behavior.

## Audit and validation scope

Confirmed blockers fixed: the private builder rejected main; Focal 3 CI watched only its old integration branch; the current installation guide directed a cloud test to a non-secret IPA. The builder now allows manual main builds while retaining all credential/delivery checks. CI covers main pushes and main-targeting PRs. The validator uses the environment where PyYAML was installed. App source, READY thresholds, capture behavior, Sony, gallery, editor, effects and backup sources are unchanged in this change.

The isolated source snapshot was matched against all 263 Git blob hashes at main b2957b73c83e70c26c2f75ee4de88611d5eb8cc6. The local private-build suite passes 32 tests with the Windows symlink test skipped. The public IPA suite's POSIX executable and symlink cases cannot be established on this Windows sandbox; Linux/macOS CI exercises them. SwiftUI/AVFoundation execution and unsigned arm64 archives require the macOS CI job. Physical iPhone, real Gemini access and AltStore installation must be verified by the owner; the checklist above is not a completed device test. A passing suite cannot establish absence of every camera or scene-specific bug.
