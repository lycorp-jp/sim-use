// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

@Suite("BundleIdentifierResolver — launchctl parsing")
struct BundleIdentifierResolverTests {

    @Test("Extracts bundle id from UIKitApplication label")
    func extractsBundleId() {
        let bundleId = BundleIdentifierResolver.bundleId(fromLabel: "UIKitApplication:com.example.MyApp[1234][b-xyz]")
        #expect(bundleId == "com.example.MyApp")
    }

    @Test("Returns nil for non-UIKitApplication labels")
    func ignoresDaemonLabel() {
        #expect(BundleIdentifierResolver.bundleId(fromLabel: "com.apple.mediaserverd") == nil)
        #expect(BundleIdentifierResolver.bundleId(fromLabel: "com.apple.SpringBoard") == nil)
    }

    @Test("Handles UIKitApplication label without bracket suffix")
    func handlesNoBrackets() {
        let bundleId = BundleIdentifierResolver.bundleId(fromLabel: "UIKitApplication:com.example.MyApp")
        #expect(bundleId == "com.example.MyApp")
    }

    @Test("Parses launchctl list output and finds pid")
    func parsesMatchingPid() {
        let output = """
        PID	Status	Label
        -	0	com.apple.something
        12345	0	UIKitApplication:com.example.app[5678][a-1234]
        67890	-	com.apple.other.service
        """
        #expect(BundleIdentifierResolver.parse(launchctlOutput: output, pid: 12345) == "com.example.app")
    }

    @Test("Returns nil when pid not present")
    func returnsNilForMissingPid() {
        let output = """
        PID	Status	Label
        12345	0	UIKitApplication:com.example.app[5678][a-1234]
        """
        #expect(BundleIdentifierResolver.parse(launchctlOutput: output, pid: 999) == nil)
    }

    @Test("Skips header and empty lines")
    func skipsHeader() {
        let output = """
        PID Status Label

        100 0 UIKitApplication:com.bundle.id[xx]
        """
        #expect(BundleIdentifierResolver.parse(launchctlOutput: output, pid: 100) == "com.bundle.id")
    }

    @Test("Returns nil for system-daemon-only output")
    func systemOnlyReturnsNil() {
        let output = """
        100	0	com.apple.SpringBoard
        200	0	com.apple.mediaserverd
        """
        #expect(BundleIdentifierResolver.parse(launchctlOutput: output, pid: 100) == nil)
    }

    // MARK: - appsByPid (full hosted-app map for liveness tracking)

    @Test("appsByPid maps every running UIKitApplication row to its bundle id")
    func appsByPidMapsRunningApps() {
        let output = """
        PID	Status	Label
        -	0	UIKitApplication:com.example.notrunning[0000][a-0]
        100	0	UIKitApplication:com.example.app[5678][a-1234]
        200	0	UIKitApplication:com.example.other[9999][b-1]
        300	0	com.apple.mediaserverd
        400	0	com.apple.SpringBoard
        """
        let map = BundleIdentifierResolver.appsByPid(launchctlOutput: output)
        #expect(map == [100: "com.example.app", 200: "com.example.other"])
    }

    @Test("appsByPid is empty for daemon-only / blank output")
    func appsByPidEmptyForDaemons() {
        #expect(BundleIdentifierResolver.appsByPid(launchctlOutput: "100\t0\tcom.apple.mediaserverd").isEmpty)
        #expect(BundleIdentifierResolver.appsByPid(launchctlOutput: "").isEmpty)
    }

    // MARK: - Foreground resolution (recognises SpringBoard's daemon label)

    @Test("foregroundBundleId maps the SpringBoard daemon label to its canonical bundle id")
    func foregroundResolvesSpringBoard() {
        // SpringBoard's launchctl label is the plain daemon form
        // `com.apple.SpringBoard`, not `UIKitApplication:` — but it is
        // the foreground after a crash, so the header must name it.
        #expect(BundleIdentifierResolver.foregroundBundleId(fromLabel: "com.apple.SpringBoard") == "com.apple.springboard")
        #expect(BundleIdentifierResolver.foregroundBundleId(fromLabel: "UIKitApplication:com.x[1]") == "com.x")
        #expect(BundleIdentifierResolver.foregroundBundleId(fromLabel: "com.apple.mediaserverd") == nil)
    }

    @Test("parseForeground resolves SpringBoard by pid where parse (apps-only) would not")
    func parseForegroundFindsSpringBoard() {
        let output = """
        PID	Status	Label
        51146	0	com.apple.SpringBoard
        51950	0	UIKitApplication:com.apple.mobilesafari[1][a]
        """
        #expect(BundleIdentifierResolver.parseForeground(launchctlOutput: output, pid: 51146) == "com.apple.springboard")
        #expect(BundleIdentifierResolver.parse(launchctlOutput: output, pid: 51146) == nil)
        #expect(BundleIdentifierResolver.parseForeground(launchctlOutput: output, pid: 51950) == "com.apple.mobilesafari")
    }

    // MARK: - Foreground resolution reusing the daemon's liveness snapshot

    private func element(pid: Int?) throws -> AccessibilityElement {
        let json = pid.map { "{\"pid\":\($0)}" } ?? "{}"
        return try JSONDecoder().decode(AccessibilityElement.self, from: Data(json.utf8))
    }

    @Test("resolve reuses a cached snapshot that already carries the root pid (no launchctl)")
    func resolveReusesCachedSnapshot() throws {
        let root = try element(pid: 99)
        let snapshot = AppSnapshot(appsByPid: [99: "com.cached.app"])
        let resolved = BundleIdentifierResolver.resolve(
            udid: "UNREACHABLE-UDID", rootElement: root, cachedSnapshot: snapshot
        )
        #expect(resolved == "com.cached.app")
    }

    @Test("resolve falls back (and stays I/O-cheap) when the root has no pid")
    func resolveFallsBackWithoutPid() throws {
        let root = try element(pid: nil)
        // No pid → the fast guard in the underlying resolver returns ""
        // without spawning launchctl, regardless of the cached snapshot.
        let resolved = BundleIdentifierResolver.resolve(
            udid: "UNREACHABLE-UDID", rootElement: root, cachedSnapshot: AppSnapshot(appsByPid: [1: "x"])
        )
        #expect(resolved == "")
    }
}