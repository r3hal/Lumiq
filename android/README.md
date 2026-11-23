# Lumiq for Android

This is a native Android version of Lumiq, written in Kotlin with Jetpack Compose and CameraX. It sits next to the iPhone app (`../Focal`) in the same repository and does not change it.

## Install on a Samsung (or any Android 8+) phone

1. In Codemagic, start the **`android-apk`** workflow ("Lumiq - Android APK"). It runs on Linux and needs no Apple account or Mac.
2. When the build finishes, download **`Lumiq-android.apk`** from the build artifacts. Open the link on the phone, or copy the file over.
3. Open the APK on the phone. If Android asks, allow your browser or file manager to **Install unknown apps**. On Samsung this is under Settings › Apps › ⋮ › Special access › Install unknown apps.
4. Open Lumiq and allow camera access.

Every APK is signed with the same sideload key (`app/lumiq-sideload.keystore`), so a newer build installs over the old one and keeps your photos and settings. This key is only for personal sideloading. Do not use it for a Play Store release.

## Sony camera (Wi-Fi remote)

`sony/` ports the iPhone Sony adapter: the camera's ScalarWebAPI over its DIRECT Wi-Fi (Ctrl w/ Smartphone). Open ⋯ › Sony camera, join the camera's Wi-Fi in Android Settings, then Find camera / Connect. Live view, one-photo-per-press capture with JPEG transfer, ISO/aperture/shutter/white balance/exposure compensation (only values the camera reports, confirmed by read-back), autofocus, touch focus and AI Shot on the Sony picture. Camera traffic is bound to the Wi-Fi network (the camera has no internet) and only private camera addresses are accepted. Protocol and workflow logic are unit-tested; it has not yet been tested with a physical camera.

## In-app updates (GitHub Releases)

Every push to `main` that changes `android/` runs [`.github/workflows/android-release.yml`](../.github/workflows/android-release.yml). It runs the unit tests and builds the release APK with the same sideload key. It then publishes `Lumiq-android.apk` and `Lumiq-android.apk.sha256` as a GitHub release tagged `android-b<versionCode>`. The versionCode is `100 + the workflow run number`, so every build is higher than the last. The build stops if the APK's package isn't `app.lumiq` or if its certificate isn't the one in `app/lumiq-sideload.keystore`.

When Lumiq starts, it quietly checks for a newer release. If it finds one, it shows **Update Now** / **Later**. Settings › Lumiq › **Check for Updates** runs the same check on demand. **Update Now** downloads the APK inside the app and shows progress. Before opening Android's installer, it verifies the file size, the SHA-256 (from GitHub's asset digest and the `.sha256` file), the package name, the versionCode and the signing certificate. Nothing installs without your confirmation in Android's prompt. Photos and settings are kept. Network, rate-limit, storage and checksum problems are reported with a Try Again button. A failed start-up check stays silent.

One-time setup:

1. **Releases must be public.** The app downloads without signing in to GitHub, so it can't read releases in a private repository. Choose one option:
   - make this repository public, or
   - create a public repository for releases only (for example `r3hal/lumiq-releases`, with at least one commit). Then, in this repo's Settings › Secrets and variables › Actions:
     - add the **variable** `LUMIQ_RELEASES_REPO` = `r3hal/lumiq-releases`;
     - add the **secret** `LUMIQ_RELEASES_TOKEN`: a fine-grained personal access token with *Contents: Read and write* on that repository only.
2. Under Settings › Actions › General, allow Actions to run. If releases go to this repository, also set Workflow permissions to "Read and write".
3. Install one APK built by this workflow. The repository the app checks is fixed into each build, so set up step 1 before that first build. Codemagic and Android Studio builds keep versionCode 2 and check `r3hal/lumiq` (override with the `LUMIQ_UPDATE_REPO` environment variable), so they find updates only when releases are published there.
4. **Gemini key (required):** add the repository secret `LUMIQ_GEMINI_KEY` with your key. AI Shot has no in-app setup and uses only the key built into the APK, so the workflow stops if the secret is missing. Anyone who has the APK can extract the key, so keep releases private or restrict the key in Google AI Studio.

The first time you tap Update Now, Android asks you to allow Lumiq to install unknown apps. This is a one-time prompt.

## Built-in Gemini key (AI Shot works with no setup)

The APK can include one Gemini key, so everyone who installs it can use AI Shot right away. The key never goes in git:

- **Codemagic:** in the Lumiq app settings, open Environment variables. Add `LUMIQ_GEMINI_KEY` with your key, mark it **Secret** and put it in the group **`lumiq_ai`**. Create the group before running `android-apk`. The same group feeds the iPhone workflow `ios-sideload-ai`.
- **Local builds:** add `lumiq.geminiKey=YOUR_KEY` to `android/local.properties`. That file is gitignored.

AI Shot has no in-app setup: it uses only the built-in key. Anyone holding the APK can extract it.

AI Shot tries `gemini-flash-lite-latest` first, because it usually answers in about 1 second. If that model is busy or over quota, the app tries `gemini-flash-latest`, then the Gemma 4 vision model, then flash-lite once more. A model that just failed with busy, quota or timeout is skipped for 2 minutes, so the next tap doesn't wait on it again.

## Build locally

You need JDK 17 and the Android SDK (platform 36). Android Studio includes both.

```sh
cd android
./gradlew assembleRelease          # app/build/outputs/apk/release/app-release.apk
./gradlew testReleaseUnitTest      # AI Shot parsing/validation, tracker
```

## iPhone → Android mapping

| iPhone (Swift) | Android (Kotlin) |
|---|---|
| SwiftUI `CameraView` | Compose `camera/CameraScreen.kt` (same layout: logo bar, aspect/exposure row, viewfinder, library · shutter · ✦ AI Shot) |
| AVFoundation `CameraController` | CameraX `camera/CameraController.kt`. A `ViewPort` crops capture and analysis to exactly what the viewfinder shows. |
| AI Shot (`AIShotModel`, `AIShotService`) | `aishot/`: same state machine, prompt, crop rules and Lumiq AI server / Gemini support |
| Vision `VNTrackObjectRequest` | `aishot/AIShotTracker.kt`, an on-device normalized cross-correlation tracker |
| Classic live guide (Vision saliency) | `camera/LiveGuide.kt`, using on-device ML Kit object detection and rule-of-thirds guidance |
| Keychain (Gemini key) | Android Keystore AES-GCM (`aishot/AIShotConfig.kt`) |
| UserDefaults | SharedPreferences (`settings/AppSettings.kt`) |
| Photo library and editor | `library/`, `editing/`: private library, share, delete, film looks, light/color/effects, rotate |
| "Also Save to Photos" | "Also save to Gallery" (Pictures/Lumiq via MediaStore) |
| Launch screen, app icon, splash | Adaptive icon + Android 12 splash + animated `LumiqSplash`, same brand geometry |

These iPhone-only features are not part of the Android build:

- RAW/ProRAW and the PRO manual controls
- Photo Backup
- Evaluation Lab
- Precision overlays (histogram, zebra, peaking)
- Insights/Compare
- Reference overlay
- The experimental Cloud Scan, which AI Shot replaces
