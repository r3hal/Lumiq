import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Built-in Gemini key for AI Shot. Never committed: it comes from android/local.properties
// (lumiq.geminiKey=...) or the LUMIQ_GEMINI_KEY environment variable (Codemagic secret).
val builtInGeminiKey: String = run {
    val local = Properties()
    val file = rootProject.file("local.properties")
    if (file.exists()) file.inputStream().use { local.load(it) }
    (local.getProperty("lumiq.geminiKey") ?: System.getenv("LUMIQ_GEMINI_KEY") ?: "").trim()
}

android {
    namespace = "app.lumiq"
    compileSdk = 36

    defaultConfig {
        applicationId = "app.lumiq"
        minSdk = 26
        targetSdk = 36
        versionCode = 2
        versionName = "3.2.1-android"
        buildConfigField("String", "BUILT_IN_GEMINI_KEY", "\"${builtInGeminiKey.replace("\"", "")}\"")
    }

    // Fixed sideload key so each new APK installs over the previous one.
    // Personal sideloading only; it is not a Play Store upload key.
    signingConfigs {
        create("sideload") {
            storeFile = file("lumiq-sideload.keystore")
            storePassword = "lumiq-sideload"
            keyAlias = "lumiq"
            keyPassword = "lumiq-sideload"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("sideload")
        }
        debug {
            signingConfig = signingConfigs.getByName("sideload")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin { jvmToolchain(17) }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.07.00")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("androidx.core:core-splashscreen:1.0.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.2")
    implementation("androidx.exifinterface:exifinterface:1.4.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    val camerax = "1.4.2"
    implementation("androidx.camera:camera-core:$camerax")
    implementation("androidx.camera:camera-camera2:$camerax")
    implementation("androidx.camera:camera-lifecycle:$camerax")
    implementation("androidx.camera:camera-view:$camerax")

    // On-device subject detection for the classic live guide (bundled model, works offline).
    implementation("com.google.mlkit:object-detection:17.0.2")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
}
