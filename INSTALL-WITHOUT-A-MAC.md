# Install Focal on your iPhone without owning a Mac

**This page covers the paid TestFlight option.** For free personal testing using Windows and AltStore Classic, use [INSTALL-FOR-FREE.md](INSTALL-FOR-FREE.md) instead.

The native app must first be compiled and signed. Downloading the source ZIP to an iPhone does not install it. Codemagic supplies the Mac build machine; Apple's TestFlight installs the resulting app on your phone.

## 1. Check the build first

1. Download and unzip `Focal.zip` on your Windows/Linux computer (a browser-based Git editor also works).
2. Create a private GitHub repository. Upload the **contents** of the extracted `Focal` folder. `codemagic.yaml` and `Focal.xcodeproj` must be at the repository root, not inside an extra enclosing folder.
3. Sign up at https://codemagic.io/ and connect this repository. Choose the YAML configuration.
4. Run **Focal - build and test (no Apple signing required)** (`ios-check`). This runs the first real Apple-toolchain compilation and the eight composition tests. Fix any reported build errors before attempting distribution. The source has only been statically checked in its authoring environment.

This first workflow does **not** produce an installable iPhone app. It verifies the source using a cloud Mac. Check Codemagic's current build quotas/pricing when signing up.

## 2. Connect your Apple account

1. Enroll in the Apple Developer Program: https://developer.apple.com/programs/enroll/. Paid membership is required for this TestFlight distribution route.
2. In the Apple Developer portal, register an explicit app identifier such as `com.yourname.focal`.
3. In https://appstoreconnect.apple.com/, create a new iOS app record using that identifier. Pick an available app name and any unique SKU.
4. In App Store Connect → Users and Access → Integrations → App Store Connect API, create a dedicated API key with App Manager access. Download its `.p8` file and note the Key ID and Issuer ID.
5. Add that key in Codemagic → Team settings → Team integrations → Developer Portal. Name the integration **Focal App Store Connect**, exactly as written in the workflow.
6. In Codemagic → Code signing identities, generate/download and upload an **Apple Distribution** certificate following Codemagic's instructions. Create a matching App Store provisioning profile for your app identifier and certificate in Apple's portal, then fetch/upload it in Codemagic. Confirm the profile and certificate match.

Put private keys only in Codemagic's credential settings, never in your Git repository or a chat message.

## 3. Build and upload

1. Edit `codemagic.yaml` in your repository. Replace **both** `com.example.focal` values with your registered identifier. The workflow updates the Xcode project automatically during the build.
2. Run **Focal - signed upload for TestFlight** (`ios-testflight`). It signs and uploads the app to App Store Connect. It does not publish to the public App Store.
3. Wait for Apple to process the build. In App Store Connect, complete any requested export-compliance or test-information prompts accurately.
4. Open your app's **TestFlight** tab. Create an **internal testing** group, add your own eligible App Store Connect user, and add the processed build to that group.

## 4. Install on your phone

1. Install Apple's **TestFlight** app from the App Store.
2. Open the internal-test invitation on your iPhone and accept it.
3. In TestFlight, tap **Install** next to Focal.
4. Open Focal from its Home Screen icon and allow Camera access.

You now have the native app on your phone. TestFlight builds expire after 90 days; upload a new build to continue testing. You do not need a public App Store listing for internal testing. External testing has additional review requirements.

## Official references

- Native iOS setup and signing: https://docs.codemagic.io/yaml-quick-start/building-a-native-ios-app/
- Apple Developer enrollment: https://developer.apple.com/programs/enroll/
- TestFlight: https://developer.apple.com/testflight/

The cloud workflows are supplied as configuration; they have not been run or connected to your accounts in this workspace.
