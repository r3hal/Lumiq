# Focal 3.0 prioritized next steps

1. **Keep CI green for follow-up changes.** Focal 3 validation runs on pushes to main and pull requests targeting main; it can also be started manually. Check its Linux/macOS results before installing a new personal build.
2. **Verify AI framing on an iPhone 16 Pro Max.** Capture a development trace while aiming at a seated person, a chair, and an outdoor landscape. Confirm the stable plan ID, measured bounds/confidence, target zoom, actual `videoZoomFactor`, manual pinch cancellation, focus-point changes, READY entry/expiry, interruption and resume. Keep captures user-initiated.
3. **Verify camera and Sony regressions.** Test RAW/ProRAW availability by device/format, camera interruptions, lens switching, autofocus while zooming, and a single A7 III connection in M/A/S. Record actual device results; do not infer them from simulator tests.
4. **Deploy the cloud proxy before enabling any shared-device scan.** Add a separately authenticated owner-controlled HTTPS service, short-lived enrollment credentials, revocation, strict request limits, retention policy, secret rotation and audit redaction. Test with synthetic images first. Keep provider keys server-side and preserve the scan disclosure and opt-out.
5. **Validate owner Drive backup on enrolled devices.** Confirm explicit consent, target-folder permission, capture IDs, original HEIC/JPEG/DNG bytes, offline recovery, account change/revocation and background transfer behavior. Verify files appear in the exact folder and then sync to Windows Drive for desktop. Do not use friends' devices until enrollment and consent work end to end.
6. **Prepare the next personal iPhone build.** For a live Gemini scan, select branch `main` and workflow `ios-cloud-personal`, enable SSH/VNC access, and use the encrypted key plus temporary private SCP delivery in [MAIN_IPHONE_TESTING.md](MAIN_IPHONE_TESTING.md). Install with AltStore. For ordinary camera testing without a Gemini key, use `ios-debug-sideload` and download the non-secret IPA from Codemagic Artifacts. Do not share a key-bearing private build.

## Known setup not included in this integration

- No Google Drive proxy endpoint, owner service credentials, or device enrollment service is configured.
- No real Gemini inference credential is configured for production; the mockable proxy client does not itself provide an identity service.
- A Codemagic workflow definition can be validated locally, but an actual Codemagic run needs the project account and configured signing/build settings.
- Physical iPhone and Sony A7 III acceptance testing remains outstanding.
