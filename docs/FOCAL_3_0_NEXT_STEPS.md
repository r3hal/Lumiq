# Focal 3.0 prioritized next steps

1. **Run branch CI on macOS.** Publish `codex/focal-3-integration`, then wait for `focal3-validation.yml` to finish simulator tests, unsigned Debug and Release archives, package scanning, backend checks, and Sony protocol tests. Fix only reproducible failures and keep this branch separate from `main`.
2. **Verify AI framing on an iPhone 16 Pro Max.** Capture a development trace while aiming at a seated person, a chair, and an outdoor landscape. Confirm the stable plan ID, measured bounds/confidence, target zoom, actual `videoZoomFactor`, manual pinch cancellation, focus-point changes, READY entry/expiry, interruption and resume. Keep captures user-initiated.
3. **Verify camera and Sony regressions.** Test RAW/ProRAW availability by device/format, camera interruptions, lens switching, autofocus while zooming, and a single A7 III connection in M/A/S. Record actual device results; do not infer them from simulator tests.
4. **Deploy the cloud proxy before enabling any shared-device scan.** Add a separately authenticated owner-controlled HTTPS service, short-lived enrollment credentials, revocation, strict request limits, retention policy, secret rotation and audit redaction. Test with synthetic images first. Keep provider keys server-side and preserve the scan disclosure and opt-out.
5. **Validate owner Drive backup on enrolled devices.** Confirm explicit consent, target-folder permission, capture IDs, original HEIC/JPEG/DNG bytes, offline recovery, account change/revocation and background transfer behavior. Verify files appear in the exact folder and then sync to Windows Drive for desktop. Do not use friends' devices until enrollment and consent work end to end.
6. **Review artifacts and release notes.** Download and inspect the ordinary public Debug IPA after policy checks pass. Keep the personal secret-bearing build private and manual. Do not merge or distribute the integration until CI and device evidence are reviewed.

## Known setup not included in this branch

- No Google Drive proxy endpoint, owner service credentials, or device enrollment service is configured.
- No real Gemini inference credential is configured for production; the mockable proxy client does not itself provide an identity service.
- A Codemagic workflow definition can be validated locally, but an actual Codemagic run needs the project account and configured signing/build settings.
- Physical iPhone and Sony A7 III acceptance testing remains outstanding.
