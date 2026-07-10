plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Deterministic-UI test fixture for the Android E2E suites. Mirrors
// :app's SDK / JDK conventions (compileSdk 35, minSdk 30, JDK 17) but
// is intentionally dependency-light: classic Views, no Compose, so
// every screen surfaces stable `android:id` short-names that sim-use
// exposes as `#<id>` selectors.
android {
    namespace = "com.linecorp.simuse.playground"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.linecorp.simuse.playground"
        minSdk = 30
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        getByName("debug") {
            isMinifyEnabled = false
        }
        getByName("release") {
            isMinifyEnabled = false
            // Debug-signed by intent — same posture as :app. This APK is
            // a developer-only test fixture installed via `adb install`
            // onto an operator-owned emulator/device; it is never
            // distributed through any consumer channel.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    // RecyclerView so the scroll screen exposes a Tier-1 collection
    // container: sim-use's Android list detector only assigns `#N` list
    // aliases to RecyclerView / ListView / GridView (or nodes carrying
    // collectionInfo), and `--include-offscreen` keys off the
    // recycled-but-attached off-screen cells RecyclerView leaves in the
    // a11y tree.
    implementation("androidx.recyclerview:recyclerview:1.3.2")
}
