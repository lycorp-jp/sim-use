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

// Standalone Gradle project for the Android E2E test-fixture app. It is
// deliberately NOT a module of the device-bridge build (bridge/) — the
// fixture is test-only and never bundled into the CLI, so it lives beside
// its iOS counterpart under Playgrounds/ with its own wrapper.
rootProject.name = "sim-use-playground"
include(":app")
