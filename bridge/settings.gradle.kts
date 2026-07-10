pluginManagement {
    repositories {
        gradlePluginPortal()
        google()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "sim-use-device-bridge"
include(":app")
// Test-fixture app driven by the Android E2E suites. Not bundled into
// the CLI — built on demand by scripts/build-playground-android.sh.
include(":playground")
