# Free personal testing: Windows + AltStore Classic

For the **private Gemini Cloud Scan Debug build**, follow [PERSONAL_CLOUD_SCAN_WINDOWS.md](docs/PERSONAL_CLOUD_SCAN_WINDOWS.md). The Release workflow below intentionally does not include developer credentials or enable Cloud Scan.

You do not need a paid Apple Developer membership to test this app on your own iPhone. This route requires a Windows computer, a USB cable, a regular Apple Account, and periodic refreshes. It does not use TestFlight.

## Build the IPA in the cloud

1. Download and extract Focal.zip. Upload the contents of the Focal folder to a private GitHub repository. `codemagic.yaml` must be at the repository root.
2. Create a **personal** Codemagic account and connect the repository. Codemagic currently provides individuals with 500 free monthly build minutes on its macOS M2 machines; team accounts do not get those free minutes. Stay within the allowance and do not enable paid overage for a free-only setup.
3. Run `ios-check` first to compile and run the composition tests using Apple's toolchain. This has not yet been run by the authoring workspace, so any build errors need to be resolved before proceeding.
4. Run **Focal - unsigned IPA for free personal sideloading** (`ios-sideload`). This workflow does not need Apple keys or signing certificates.
5. After a successful build, download `Focal-unsigned.ipa` from its artifacts. This is compiled app code, but still requires signing by AltStore before it will run on an iPhone.

## Install using your regular Apple Account

1. Follow AltStore's official Windows instructions: https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows. Use **AltStore Classic**, not the separate PAL marketplace.
2. Install the prerequisites specified there, install AltServer, connect your unlocked iPhone by USB, trust the computer, and use AltServer to install AltStore Classic.
3. Enter your Apple Account details in the official tool on your own computer. Do not place credentials in the Git repository, build workflow, or chat.
4. Follow the official instructions to trust your developer profile and enable Developer Mode on the iPhone.
5. Transfer the downloaded IPA to Files on the iPhone. In AltStore Classic, open My Apps, tap **+**, and select `Focal-unsigned.ipa`. Keep AltServer running and reachable while AltStore signs and installs it.
6. Open Focal from the Home Screen and allow camera access.

## The free-account limits

- Apps expire after **7 days** unless refreshed. Keep AltServer available and use AltStore's Refresh All before expiry; automatic background refresh is best-effort.
- Free accounts can have up to three sideloaded apps installed at a time, including AltStore itself.
- You need continued access to the computer for refreshing. A successful native build and compatible AltServer/AltStore setup are prerequisites, not things already completed by this source ZIP.

If you can borrow a Mac instead, opening the Xcode project and using your Apple Account's **Personal Team** also permits free on-device testing, with the same seven-day provisioning limit.

If you have only an iPhone and cannot access a computer, this route is not practical. A separately implemented web app can be added to the Home Screen from Safari for free, but the SwiftUI source cannot run in Safari and Apple's native Vision camera pipeline would need a browser-compatible alternative.

Sources checked while preparing this workflow:

- https://docs.codemagic.io/billing/pricing/
- https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows
- https://faq.altstore.io/altstore-classic/your-altstore
- https://developer.apple.com/help/account/basics/about-your-developer-account
