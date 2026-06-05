// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend

/// `sim-use app-state` — a lightweight, cross-platform read of which apps
/// are running on the device (no accessibility-tree fetch), plus the
/// `--reset` baseline control for crash detection (issue #81).
///
/// Routes through the per-UDID daemon like the interaction verbs so that
/// `--reset` re-baselines the *daemon's* `ProcessLivenessTracker` and
/// clears any pending crash signal. `managesLivenessState` keeps dispatch
/// from auto-evaluating the tracker for this command (it owns it).
struct AppState: SimUseExecutableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-state",
        abstract: "Report which apps are running on the device; --reset re-baselines crash detection."
    )

    @OptionGroup var device: DeviceOptions

    @Option(
        name: .customLong("bundle-id"),
        help: ArgumentHelp(
            "Report running|not_running for this bundle id / package only.",
            valueName: "id"
        )
    )
    var bundleId: String?

    @Flag(
        name: .customLong("reset"),
        help: "Re-baseline crash detection to the current process set and clear any pending crash signal. Use after intentionally relaunching the app, attaching to an already-running app, or accepting a crash."
    )
    var reset: Bool = false

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    var simulatorUDIDForDaemon: String? { device.resolved }

    var managesLivenessState: Bool { true }

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    // MARK: - Result

    struct AppProcess: Codable, Equatable {
        let bundleId: String
        let pid: Int
    }

    struct AppStateQuery: Codable, Equatable {
        let bundleId: String
        /// "running" | "not_running". Liveness only — the
        /// foreground-vs-background distinction needs foreground info the
        /// lightweight probe does not carry and is left to describe-ui.
        let state: String
    }

    struct ExecutionResult: Codable {
        let platform: String
        let apps: [AppProcess]
        let query: AppStateQuery?
        let didReset: Bool
    }

    func execute() async throws -> ExecutionResult {
        let udid = device.resolved
        let isAndroid = PlatformRouter.looksLikeAndroid(udid)
        let probed = isAndroid
            ? AndroidProcessLister.appSnapshot(serial: udid)
            : BundleIdentifierResolver.appSnapshot(udid: udid)

        // A nil probe means the process list could not be read (device
        // busy, mid-boot, or disconnected). Surface that as an error
        // rather than reporting a misleading empty "not_running" result.
        guard let snapshot = probed else {
            throw CLIError(errorDescription:
                "Could not read the running-process list from \(udid). " +
                "The device may be busy, mid-boot, or disconnected — retry in a moment.")
        }

        if reset {
            // In the daemon this re-baselines the live tracker; standalone
            // (no daemon) resets a per-invocation instance and is a no-op
            // across commands — documented.
            DaemonDispatch.processTracker.reset(to: snapshot, now: Date())
        }

        return Self.buildResult(
            platform: isAndroid ? "android" : "ios",
            snapshot: snapshot,
            bundleId: bundleId,
            didReset: reset
        )
    }

    /// Pure snapshot → result mapping. Exposed for tests.
    static func buildResult(
        platform: String,
        snapshot: AppSnapshot,
        bundleId: String?,
        didReset: Bool
    ) -> ExecutionResult {
        let apps = snapshot.appsByPid
            .map { AppProcess(bundleId: $0.value, pid: $0.key) }
            .sorted { $0.bundleId < $1.bundleId }
        let query: AppStateQuery? = bundleId.map { id in
            let state: String
            switch snapshot.liveness(ofBundleId: id) {
            case .alive: state = "running"
            case .dead: state = "not_running"
            }
            return AppStateQuery(bundleId: id, state: state)
        }
        return ExecutionResult(platform: platform, apps: apps, query: query, didReset: didReset)
    }

    func format(_ result: ExecutionResult) -> CommandOutput {
        var lines: [String] = []
        if let query = result.query {
            lines.append("\(query.bundleId): \(query.state)")
        }
        if result.apps.isEmpty {
            lines.append("No tracked app processes running.")
        } else {
            lines.append("Running apps (\(result.apps.count)):")
            for app in result.apps {
                lines.append("  \(app.bundleId)  pid=\(app.pid)")
            }
        }
        if result.didReset {
            lines.append("Crash-detection baseline reset.")
        }
        return .lines(lines)
    }
}