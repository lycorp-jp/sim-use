// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SimUseCore

// MARK: - Enablement

/// Android device E2E is opt-in via `SIM_USE_E2E_ANDROID` (1/true/yes),
/// mirroring the iOS `SIM_USE_E2E` gate in `TestUtilities.swift`. Kept
/// independent so the two device farms can be driven separately: an
/// Android run needs an emulator/device on `adb`, not a booted iOS
/// simulator.
let isAndroidE2EEnabled: Bool = {
    let raw = ProcessInfo.processInfo.environment["SIM_USE_E2E_ANDROID"]?.lowercased() ?? ""
    return raw == "1" || raw == "true" || raw == "yes"
}()

// MARK: - Wire shapes

/// Decodes the `describe-ui --json` envelope for Android. The tree lives
/// under `data.entries` as the cross-platform `Outline.Entry` shape (see
/// `Sources/SimUseCore/Outline.swift`) — reused verbatim rather than
/// re-declared so the test stays coupled to the real serializer.
struct AndroidDescribeEnvelope: Decodable {
    let ok: Bool
    let data: DataBlock

    struct DataBlock: Decodable {
        let appLabel: String?
        let appPackage: String?
        let entries: [Outline.Entry]
        let lists: [Outline.ListSummary]?
    }
}

/// Thin view over a decoded describe-ui result with the lookups the
/// Android suites need. `Outline.Entry.resourceId` is the short-name
/// (`tap_count`), `aliases.list` carries the `#N` list-cell handle.
struct AndroidOutline {
    let appPackage: String?
    let entries: [Outline.Entry]
    let lists: [Outline.ListSummary]

    func entry(resourceId: String) -> Outline.Entry? {
        entries.first { $0.resourceId == resourceId }
    }

    /// Text label of the element with `resourceId`, or nil if absent.
    func label(resourceId: String) -> String? {
        entry(resourceId: resourceId)?.label
    }

    /// The list cell addressed by `#index` within the first (dominant)
    /// detected list scope.
    func listCell(index: Int) -> Outline.Entry? {
        entries.first { $0.aliases.list?.index == index }
    }

    var listCells: [Outline.Entry] {
        entries.filter { $0.aliases.list != nil }
    }
}

// MARK: - Runner

enum AndroidE2E {
    static let playgroundPackage = "com.linecorp.simuse.playground"
    static let mainActivityComponent = "com.linecorp.simuse.playground/.MainActivity"

    // MARK: Environment

    static func requireEnabled() throws {
        if !isAndroidE2EEnabled {
            throw TestError.commandError(
                "Android device E2E is disabled. Run via ./scripts/test-runner-android.sh or set SIM_USE_E2E_ANDROID=1."
            )
        }
    }

    static func requireSerial() throws -> String {
        try requireEnabled()
        let raw = ProcessInfo.processInfo.environment["ANDROID_SERIAL"]
        let serial = (raw?.isEmpty == false) ? raw! : "emulator-5554"
        return serial
    }

    /// Locate the `adb` binary. `adb` is rarely on PATH in a bare test
    /// shell, so fall back to the standard SDK location the same way
    /// `scripts/build-bridge.sh` resolves the SDK root.
    static func adbPath() throws -> String {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        for key in ["ANDROID_SDK_ROOT", "ANDROID_HOME"] {
            if let root = env[key], !root.isEmpty {
                candidates.append("\(root)/platform-tools/adb")
            }
        }
        if let home = env["HOME"] {
            candidates.append("\(home)/Library/Android/sdk/platform-tools/adb")
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: rely on PATH resolution inside the bash invocation.
        return "adb"
    }

    // MARK: sim-use invocation

    /// Run `sim-use <command> --device <serial>`. On a transient
    /// `DaemonSocketError` (seen after long idle), stop the per-UDID
    /// daemon and retry once — the documented recovery.
    @discardableResult
    static func run(
        _ command: String,
        allowFailure: Bool = false
    ) async throws -> ShellOutput {
        let serial = try requireSerial()
        let simUse = try TestHelpers.getSimUsePath()
        let full = "\(simUse) \(command) --device \(serial)"

        func once() async throws -> (output: String, exitCode: Int32) {
            try await CommandRunner.run(full, allowFailure: true, timeout: 60)
        }

        var result = try await once()
        if result.output.contains("DaemonSocketError") {
            _ = try? await CommandRunner.run(
                "\(simUse) daemon stop --device \(serial)",
                allowFailure: true,
                timeout: 30
            )
            try await Task.sleep(nanoseconds: 500_000_000)
            result = try await once()
        }

        if result.exitCode != 0, !allowFailure {
            throw TestError.unexpectedState(
                "sim-use command '\(command)' failed with exit code \(result.exitCode). Output: \(result.output)"
            )
        }
        return ShellOutput(output: result.output, exitCode: result.exitCode)
    }

    // MARK: Playground control

    /// Launch (or re-deliver via singleTop) the playground on a screen.
    static func launch(screen: String) async throws {
        let serial = try requireSerial()
        let adb = try adbPath()
        _ = try await CommandRunner.run(
            "\(adb) -s \(serial) shell am start -n \(mainActivityComponent) -e screen \(screen)",
            allowFailure: true,
            timeout: 30
        )
        // Give MainActivity time to inflate + wire the screen before the
        // first describe-ui read. Screen setup resets per-screen counters,
        // so this also guarantees a clean slate.
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    // MARK: describe-ui

    static func describeUI(includeOffscreen: Bool = false) async throws -> AndroidOutline {
        let flag = includeOffscreen ? " --include-offscreen" : ""
        let result = try await run("describe-ui --json\(flag)")
        guard let data = extractJSONData(result.output) else {
            throw TestError.invalidJSON("describe-ui produced no JSON object: \(result.output)")
        }
        let envelope = try JSONDecoder().decode(AndroidDescribeEnvelope.self, from: data)
        return AndroidOutline(
            appPackage: envelope.data.appPackage,
            entries: envelope.data.entries,
            lists: envelope.data.lists ?? []
        )
    }

    /// Poll describe-ui until `predicate` holds on a freshly-read outline,
    /// or `timeout` elapses. Android delivers per-view text-change
    /// accessibility events independently and with throttling, so a single
    /// fixed-delay read can catch a partially-updated tree (e.g. a counter
    /// bumped but the sibling echo label still stale). Polling until the
    /// state settles removes that flake without hiding real failures — a
    /// wrong value simply never satisfies the predicate and the caller's
    /// `#expect` on the returned outline fails.
    @discardableResult
    // Default timeout is generous: Android accessibility text is
    // eventually-consistent (TYPE_VIEW_TEXT_CHANGED events are coalesced and
    // the a11y node cache can lag an action by seconds, more so on a loaded or
    // cold emulator), so a positive "wait until X appears" poll needs headroom.
    // The predicate short-circuits, so fast machines pay nothing.
    static func waitForOutline(
        includeOffscreen: Bool = false,
        timeout: TimeInterval = 12,
        pollInterval: TimeInterval = 0.4,
        where predicate: (AndroidOutline) -> Bool
    ) async throws -> AndroidOutline {
        let deadline = Date().addingTimeInterval(timeout)
        var ui = try await describeUI(includeOffscreen: includeOffscreen)
        while !predicate(ui), Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            ui = try await describeUI(includeOffscreen: includeOffscreen)
        }
        return ui
    }

    /// Poll `keyboard-state` until it reports `expected`, or timeout.
    static func waitForKeyboard(
        visible expected: Bool,
        timeout: TimeInterval = 8,
        pollInterval: TimeInterval = 0.4
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var visible = try await keyboardVisible()
        while visible != expected, Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            visible = try await keyboardVisible()
        }
        return visible
    }

    /// Whether the soft keyboard is currently reported visible.
    static func keyboardVisible() async throws -> Bool {
        let result = try await run("keyboard-state --json")
        guard let data = extractJSONData(result.output) else {
            throw TestError.invalidJSON("keyboard-state produced no JSON object: \(result.output)")
        }
        struct Env: Decodable {
            let data: Payload
            struct Payload: Decodable { let visible: Bool }
        }
        return try JSONDecoder().decode(Env.self, from: data).data.visible
    }

    /// Bundle ids currently reported running by `app-state`.
    static func runningPackages() async throws -> [String] {
        let result = try await run("app-state --json")
        guard let data = extractJSONData(result.output) else {
            throw TestError.invalidJSON("app-state produced no JSON object: \(result.output)")
        }
        struct Env: Decodable {
            let data: Payload
            struct Payload: Decodable {
                let apps: [App]
                struct App: Decodable { let bundleId: String }
            }
        }
        return try JSONDecoder().decode(Env.self, from: data).data.apps.map(\.bundleId)
    }

    // MARK: Parsing helpers

    /// Slice a `Data` starting at the first `{`/`[` so leading log noise
    /// (daemon spawn lines) doesn't break `JSONDecoder`.
    private static func extractJSONData(_ raw: String) -> Data? {
        guard let start = raw.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        return String(raw[start...]).data(using: .utf8)
    }

    /// Integer trailing a `"Caption: N"` echo label. Returns nil when the
    /// label is missing or the tail isn't an int (e.g. the initial "-").
    static func trailingInt(_ label: String?) -> Int? {
        guard let tail = trailingValue(label) else { return nil }
        return Int(tail)
    }

    /// Value after the first `": "` in a `"Caption: value"` echo label.
    static func trailingValue(_ label: String?) -> String? {
        guard let label, let range = label.range(of: ": ") else { return nil }
        return String(label[range.upperBound...])
    }
}
