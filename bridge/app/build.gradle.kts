plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.linecorp.simuse.devicebridge"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.linecorp.simuse.devicebridge"
        minSdk = 30
        targetSdk = 35
        versionCode = 16
        versionName = "0.9.0"

        // Must match `BridgeClient.expectedProtocolVersion` on the
        // Swift side — bump both together on breaking wire changes
        // only (see CLAUDE.md). Bumped to 2: `/a11y_tree_full`
        // may now return a synthetic root with `className =
        // "__simuse:multi_window__"` when the app has secondary
        // windows (PopupWindow / dialog / dropdown). Old clients would
        // render the wrapper as an opaque node — bumping forces them
        // to upgrade.
        buildConfigField("int", "PROTOCOL_VERSION", "2")
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            // Debug-signed by intent: sim-use (including this bridge) is
            // internal developer tooling — installed via `sim-use android
            // init` → `adb install` onto an emulator or developer-owned
            // device. The Android debug signing key is public, so this
            // signature carries no authenticity guarantee; that is
            // acceptable because the install channel is trusted (the
            // operator runs `adb` against their own hardware) and the
            // bridge is never distributed through Play or any consumer
            // channel. See `AGENTS.md` → "Distribution posture (developer
            // tool only)". Switch to a real release signing config
            // before any consumer / GA distribution.
            signingConfig = signingConfigs.getByName("debug")
        }
        getByName("debug") {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    testImplementation("io.mockk:mockk:1.13.10")
}
