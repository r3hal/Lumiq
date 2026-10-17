# Private Cloud Scan test: Windows, Codemagic and AltStore

This prepares one personal Debug IPA for your iPhone 16 Pro Max. Use branch **codex/focal-cloud-composition-scan** and workflow **ios-cloud-personal**. No Mac, paid Apple Developer membership, distribution certificate or App Store export is required. AltStore/AltServer must still sign and provision the app normally before iOS can run it.

## First: replace the previously committed credential

A follow-up commit put a real credential in DeveloperExamples/CloudComposition.example.json. The example has been restored to the placeholder without copying the credential to this workspace or using it for a provider call. Removing it from the current tree does **not** remove it from Git history.

1. Revoke that credential in your Google AI Studio/Google Cloud API-key settings.
2. Create a replacement for this private test. Keep the Generative Language API restriction and a small project quota/budget appropriate for personal testing. Review your project's application restrictions; the workflow does not bypass restrictions, use another model, or suggest disabling certificate/signature checks.
3. Enter the replacement only into Codemagic's encrypted variable described below. Do not paste it into chat, GitHub, an example, a local source file, a build argument or a screenshot.
4. Do not run an older branch revision that still contains the real example value. Current structural validation requires the placeholder.

History was not rewritten or force-pushed. Revocation is required even for a private repository. Anyone who already obtained a key-bearing IPA can extract its key. Embedding a secret is acceptable only as this explicitly requested, temporary personal experiment; the production proxy requirement remains unchanged. [Google key guidance](https://ai.google.dev/gemini-api/docs/api-key).

## What was inspected and preserved

- Existing ios-sideload and ios-evaluation archive Release, disable signing only for the intermediate app, then place Focal.app inside Payload/ using ditto. AltStore supplies the final development signature. Their text and behavior remain unchanged.
- Existing GeminiCloudConfiguration reads exactly model and apiKey from CloudComposition.local.json, inside DEBUG only. The existing Xcode resource phase copies the ignored LocalDeveloper file only for Debug and removes it for Release. No Swift code or project settings were changed by this preparation.
- The new workflow uses Debug explicitly, confirms DEBUG in effective settings, and opts the Focal executable out of Xcode's optional debug-dylib layout with ENABLE_DEBUG_DYLIB=NO. This changes the Debug product layout, not iOS signature enforcement, sandbox entitlements or camera logic. [Apple layout documentation](https://developer.apple.com/documentation/xcode/understanding-build-product-layout-changes).
- Sony, local Guide, READY, manual zoom/focus, shutter, gallery, editor, film effects and Google Drive sources are byte-identical to the incoming branch.

## Why this workflow has no downloadable artifact card

Codemagic documents 30-day artifact retention for personal accounts. Public artifact links are bearer links, and a short link expiration does not shorten the stored artifact's retention. No verified per-workflow short-retention/delete setting is used here. [Retention](https://docs.codemagic.io/billing/pricing/), [artifact authentication/public links](https://docs.codemagic.io/rest-api/artifacts/).

The new workflow therefore has artifacts: [], no publishing, no cache and no automatic trigger. The helper also rejects webhook/scheduled provenance and any overlap with Codemagic's independently collected CM_EXPORT_DIR. It does not send an IPA by email/Slack, create a public URL, or upload a key-bearing file to GitHub Actions. Download privately from the temporary build VM using Codemagic SSH and SCP. The IPA is removed on your SHA-256 acknowledgement or after 15 minutes. Source configuration, archived app, staging copy, DerivedData and private build log are removed **before** that download window begins.

Normal exceptions, timeout and SIGTERM clean up owned files. A forced machine kill can prevent Python cleanup; Codemagic VM teardown remains the boundary in that case. This is not a promise of secure erasure from the provider's infrastructure. The build still contains your developer secret while it exists. Use your personal account, private repository and trusted computer; do not upload the IPA to an analysis service.

## 1. Set the encrypted Codemagic variable

1. Open your existing Focal application in Codemagic and confirm it points at private repository r3hal/focal-private.
2. Open the app-level **Environment variables** tab. Create group **focal_cloud_personal**; do not make it a broadly shared team group.
3. Add variable name **GEMINI_API_KEY**. Enter the replacement key directly in Codemagic's value field. Select **Secret** before saving. That option encrypts/masks it; the build cannot determine from the environment whether you selected it.
4. Do not add this variable to Git, codemagic.yaml, global workflow variables, CM_ENV, or other workflow groups.
5. The YAML explicitly sets **GEMINI_MODEL: gemini-3.8-flash**. Keep that value for the first test. A deliberate model change must be documented and checked against Google's current image/structured-output support and pricing; the script never substitutes a model.
6. Confirm you have enough Codemagic macOS build minutes. The download wait consumes build time; acknowledge promptly.

The workflow imports only the new group. It disables shell tracing and removes GEMINI_API_KEY from the environments passed to Xcode, git and packaging tools. The actual key is written only by Python into the ignored config with owner-only permissions; raw provider responses and sensitive build output are not published. [Codemagic encrypted variables](https://docs.codemagic.io/yaml-basic-configuration/configuring-environment-variables/).

## 2. Start the correct manual build

1. In Codemagic choose **Start new build**.
2. Select branch **codex/focal-cloud-composition-scan** and workflow **Focal - PRIVATE Debug Cloud Scan (SSH download only)** / **ios-cloud-personal**.
3. Select **Enable SSH/VNC access** before starting. It must be enabled for each build. Prepare Git Bash on Windows for Codemagic's generated SSH connection script.
4. Start the build. No push, PR or tag event automatically starts this workflow. Its credential-bearing builder also refuses main, other branches, tags and PR contexts.
5. Watch the unit and native regression steps. No developer config exists during native tests.
6. The private build step then verifies Google access and archives the Debug device app. It prints LIVE MODEL CHECK PASSED only after the real project check succeeds. It prints PRIVATE DEBUG IPA READY and a download path/hash only after IPA validation succeeds.

Codemagic creates temporary SSH credentials for each build. Use only the command supplied by your own authenticated build page, and never post that script/private key. [Codemagic remote access](https://docs.codemagic.io/troubleshooting/accessing-builder-machine-via-ssh/), [manual YAML builds](https://docs.codemagic.io/yaml-basic-configuration/yaml-getting-started/).

## 3. Download privately to Windows during the 15-minute window

1. In the running build, choose **Explore build machine via SSH or VNC/RDP client**. Follow the supplied SSH connection instructions in **Git Bash**. Keep the SSH terminal open.
2. Note the SSH host, port, user and identity-file path from that generated connection command. They are build-specific; never reuse credentials from an old build. Retain any required proxy/jump options. Do not turn off SSH host-key checking to resolve a mismatch.
3. In a second Git Bash window, download the IPA using those same connection parameters. Replace the angle-bracket placeholders with the values from your build. SCP uses uppercase -P for the port.

~~~bash
mkdir -p /c/FocalPrivateTest
scp -P <SSH_PORT> -i "<IDENTITY_FILE>" \
  <SSH_USER>@<SSH_HOST>:/Users/builder/clone/build/private-cloud/Focal-CloudScan-Debug-unsigned.ipa \
  /c/FocalPrivateTest/Focal-CloudScan-Debug-unsigned.ipa
~~~

Use the exact **SCP source** path printed by the build if its clone directory differs from /Users/builder/clone. If the official SSH command uses proxy/jump options, carry those options into SCP as well; do not replace the connection with a public file-sharing service. If you cannot establish the official SSH connection, let the workflow time out and remove its copy.

4. In Windows PowerShell, calculate the downloaded file's SHA-256:

~~~powershell
(Get-FileHash -Algorithm SHA256 -LiteralPath 'C:\FocalPrivateTest\Focal-CloudScan-Debug-unsigned.ipa').Hash
~~~

5. Compare it with the build's SHA256 line. If it differs, do not install or acknowledge; retry the transfer before timeout.
6. Once it matches, run the acknowledgement command printed by the build in the **remote SSH terminal**, not Windows PowerShell:

~~~bash
cd "$CM_BUILD_DIR"
python3 scripts/build_personal_cloud_ipa.py downloaded --sha256 <MATCHING_SHA256>
~~~

7. Wait for Download acknowledged; private build files removed and successful workflow completion. There is intentionally no IPA in Codemagic's Artifacts section. Disconnect SSH.
8. Keep the Windows copy outside OneDrive/iCloud/shared folders. Delete it when the personal install/test or necessary refresh is finished; it is a credential-bearing file.

SCP transport and your actual Codemagic account's remote-access availability still need your first manual run. The tooling's mock tests do not establish that your SSH endpoint is reachable.

## 4. Sign/install on the iPhone 16 Pro Max

Use **AltStore Classic / AltServer for Windows**, not AltStore PAL. Keep your existing regular Apple Account and installed Focal bundle identity; no bundle-ID change is introduced. Export any irreplaceable local photos before changing an installation. Do not uninstall Focal to make an update work.

If your existing AltServer setup already works, keep it. Otherwise follow the official Windows prerequisites, including the supported Apple iTunes/iCloud installers, USB trust/pairing and AltStore installation. Trust the developer profile and enable **Settings > Privacy & Security > Developer Mode** when iOS requires it. Enter Apple credentials only in the official local tool. [Official Windows setup](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows).

The shortest private Windows route avoids copying this IPA through cloud storage:

1. Connect the unlocked iPhone by USB and keep AltServer running.
2. Hold **Shift** while opening the AltServer tray menu and select **Sideload .ipa…**.
3. Select C:\FocalPrivateTest\Focal-CloudScan-Debug-unsigned.ipa, choose your iPhone and sign with your regular Apple Account. Let AltServer apply its normal development signature/provisioning.
4. If you instead use your established AltStore Classic **My Apps > +** route, transfer the IPA to a private local Files location using your existing trusted method, then select it there with AltServer reachable. Do not create a public download/source URL.
5. Open Focal and grant camera access. An unsigned intermediate cannot run directly from Files; signing must succeed first.

Direct IPA sideloading is documented by AltServer. It can require manual reinstallation after seven days; do not assume every directly installed IPA appears in AltStore's refresh list. AltStore-managed apps also expire after seven days without refresh, and free accounts have a three-app limit including AltStore. Keep normal limits/signature checks enabled. No jailbreak, JIT activation, altered entitlement or paid distribution profile is required. [AltServer direct sideloading](https://faq.altstore.io/release-notes/altserver), [AltStore expiry/limits](https://faq.altstore.io/altstore-classic/your-altstore).

An arm64 iPhoneOS Debug archive is the expected input to this existing sideload route. CI validates its structure; actual AltServer re-signing, installation and launch on your phone remain separate checks.

## 5. Perform the first live Gemini composition scan

1. First confirm local AI Guide works, manual zoom/focus still have priority, and no photo is captured without your shutter action. Compare scan-disabled and scan-enabled behavior within this same Debug build; its existing optimization level differs from Release.
2. Select the iPhone source and **Automatic composition** mode. Enable AI Guide.
3. Use a non-sensitive, well-lit scene with a clearly tracked person, pet or object. Start with Auto Zoom OFF to isolate cloud planning from motor behavior.
4. Long-press the AI Guide button, select **Cloud AI Scan (Experimental)**, read/acknowledge the Google disclosure, and press **Send one frame to Google**.
5. Confirm that a verified result locks one composition, then return to the viewfinder. Tracking/arrows/READY remain local. Hold READY without pressing the shutter: no capture should occur.
6. Pinch manually, briefly lose/reacquire the subject, introduce a competing subject and disconnect internet. Check target retention, bounded recovery, stale-result rejection and offline local guidance. Repeat with Auto Zoom ON.
7. Check Sony A7 III source switching/Live View/controls, gallery and editor before relying on this build. Those sources are unchanged, but shared app runtime still needs a device smoke test.
8. After the experiment, revoke the temporary key if no longer needed, remove obsolete Codemagic variable values, and delete unnecessary local IPA copies. An installed/cached IPA still contains the key; revocation is what makes old copies unusable for Google access.

The first scan per service instance makes its own metadata GET and one JPEG generation request. The build preflight uses one GET and one text-only generation request. No camera image is sent by the build, no repeated requests occur while guiding, and successful text preflight does not prove useful image reasoning.

## Model checks, costs and failure behavior

Documentation checked 2026-10-17 lists gemini-3.8-flash with image input, structured output and a free tier. Free-tier eligibility, available quota and any billing-enabled project charges are account-specific. Check those in Google AI Studio; do not enable paid billing just to work around a failure. [Model](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash), [pricing](https://ai.google.dev/gemini-api/docs/pricing), [models API](https://ai.google.dev/api/models), [structured output](https://ai.google.dev/gemini-api/docs/generate-content/structured-output).

| Failure | Result and next action |
| --- | --- |
| Missing/invalid variable, wrong branch, pre-existing config/output | Refuse without overwriting work. Correct setup and start a fresh build. |
| Google 401/403 | Stop; inspect key/project permissions and restrictions in Google settings. Do not paste the key/error body into chat or weaken restrictions to force a pass. |
| Google 404 or missing generation capability | Stop; the selected model is unavailable. No fallback is chosen. Review current model documentation before an explicit model change. |
| Quota 429, timeout, TLS/network failure, malformed/blocked/truncated text probe | Stop without retry or IPA delivery. Check quota/connectivity and try a new manual build when resolved. |
| Wrong Debug settings, simulator platform, mismatched embedded config, invalid IPA layout | Stop and clean up. Do not force-install, remove entitlements, bypass verification or enable Cloud Scan in Release. |
| Private output overlaps CM_EXPORT_DIR | Stop before building. The account's automatic-export configuration must not cover the private workspace; do not relax this guard. |
| No SSH access/download acknowledgement within 15 minutes | Remove the private output and fail. Enable the official remote access option and rebuild; do not add a public artifact pattern. |
| AltStore rejects signing/launch | Keep normal signing checks. Record the non-secret error code and use the official troubleshooting steps; the binary is not yet an installed/tested build. |

If your Codemagic plan/network cannot provide its documented temporary SSH access, this strict short-retention route is blocked at private delivery. The smallest alternatives are to obtain that access or borrow a Mac for a local Personal Team Debug build. A normal retained/public artifact or a Release build with DEBUG forced on would not meet these requirements. An authenticated backend is the separate production solution, not work started here.

## Files and validation evidence

Changed build files: codemagic.yaml, scripts/build_personal_cloud_ipa.py, scripts/test_personal_cloud_native.py, scripts/tests/test_personal_cloud_ipa.py, scripts/validate_structure.py and .github/workflows/cloud-composition-validation.yml. The example placeholder was restored; installation/Cloud Scan documentation points here. No Swift, entitlement, signing identity, bundle ID or camera-function source was edited.

Build-tooling revision: `ca91b2074dacc0971eb5a6bb14064a582d04c9ab`. [GitHub Actions run 39027224680](https://github.com/r3hal/focal-private/actions/runs/39027224680) completed successfully on 2026-10-17. The subsequent delivery commit changes documentation only.

| Check | Result |
| --- | --- |
| Portable private-build regression suite | **24 tests passed**. Covers exact config schema, secret-free child environments and diagnostics, manual branch/trigger restrictions, Google status/timeout/response failures with no retry/fallback, metadata + text probe contract, owner-only config, overwrite/symlink refusal, Debug-policy enforcement, device/IPA validation, export overlap, acknowledgement and cleanup. All provider responses and keys are fixtures. |
| Untouched Phase 1 baseline | **358 framing + 75 Sony tests passed**, zero failures. |
| Current portable framing/cloud policies | **392 tests passed**, zero failures. |
| Current portable Sony suite | **75 tests passed**, zero failures. These overlap with the native suite; do not sum them as unique additional tests. |
| Structure / source / YAML / shell syntax | Passed deterministic project checks, historical hashes, existing shutter/READY/manual-zoom/Sony integration guards and the new private workflow contract. No app/project file changed. |
| Swift parse + native XCTest | Xcode **16.4 (16F6)**, macOS 15; iPhone 16 Pro simulator on iOS 18.5: **674 tests passed**, zero failures. |
| Existing unsigned Release archive | Passed; developer configuration absent from the Release app. |
| New personal Debug packaging smoke | **Passed a real arm64 iPhoneOS Debug archive and IPA**, with a deliberately fake credential. Verified DEBUG settings, exact embedded config, executable permissions/ZIP layout, and deletion of source config/archive/staging/IPA. No live provider request, real key, retained IPA or artifact upload was used. |
| Windows source inspection | Credential-free isolated snapshot and protected app/project source hashes verified. Native builds ran on macOS CI; Windows itself cannot run Xcode/UIKit/AVFoundation checks. |
| Your Codemagic account, rotated key, SSH/SCP and iPhone | **Not executed by this preparation session**. No browser/account connection is available. The manual workflow must verify your real project's model access; your phone must verify AltStore signing/launch and the actual image scan. |

[Portable job](https://github.com/r3hal/focal-private/actions/runs/39027224680/job/117380520603), [native tests / Release archive / Debug IPA smoke](https://github.com/r3hal/focal-private/actions/runs/39027224680/job/117380520428).

Reproduce portable checks with `python3 -m unittest discover -s scripts/tests -p test_personal_cloud_ipa.py -v`, `python3 scripts/validate_structure.py`, `python3 scripts/test_framing_portable.py` and `python3 scripts/test_sony_portable.py`. The macOS CI workflow records the exact Xcode commands and runs `env -u GEMINI_API_KEY python3 scripts/test_personal_cloud_native.py` only with a fixture credential.

The runtime project preflight is intentionally **not** bypassed by a green CI result. It must make its real GET/text request with your encrypted Codemagic variable before a key-bearing IPA can be prepared. Account restrictions, quota, network reachability, AltServer compatibility and physical camera behavior remain the first personal run's checks.

Do not confuse these checks with a completed personal installation. This task has no access to your rotated Codemagic secret, Apple Account or iPhone; the real-project model probe, key-bearing IPA, private transfer, AltStore signature and live image scan require your manual Codemagic/phone run. No real key was requested, printed, copied to this workspace or used for a provider call, and no image was sent to Google during preparation.
