// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Resolves the device identifier (iOS Simulator UDID or Android adb
/// serial) a device-scoped command should run against when the user
/// does not pass `--device` (or its deprecated alias `--udid`)
/// explicitly. Resolution order:
///
///   1. Explicit `--device <X>` / `--udid <X>` (caller's responsibility,
///      not seen here).
///   2. `SIM_USE_DEVICE` or `SIM_USE_UDID` environment variable —
///      per-shell-session override. Setting both is a fast-fail.
///   3. Exactly one live sim-use daemon under `/tmp/sim-use-<uid>/` — the
///      "you've been working on this simulator already" steady-state path.
///      Cost: <1 ms (a directory scan + a few stat() calls).
///   4. Exactly one simulator with `state == "Booted"` per
///      `xcrun simctl list devices booted -j`. Cost: ~150 ms (one
///      forked subprocess).
///
/// 0 / >1 results at step 3 fall through to step 4. 0 / >1 booted at
/// step 4 surface a `ResolutionError` with the list of booted UDIDs so
/// the agent can self-correct without another `list-simulators` call.
public struct DeviceResolver {

    public enum ResolutionError: LocalizedError, HintProviding {
        case noSimulatorBooted
        case multipleSimulatorsBooted(udids: [String], names: [String: String])
        case simctlFailed(message: String)
        case conflictingEnvVars

        public var errorDescription: String? {
            switch self {
            case .noSimulatorBooted:
                return "No simulator is booted. Boot one in Simulator.app (or with `xcrun simctl boot <UDID>`) and retry, or pass `--device <UDID>` explicitly."
            case .multipleSimulatorsBooted(let udids, let names):
                // Inline the booted list directly into the error message so
                // the user sees actionable info without having to look at
                // --json hint. Format: "<name> (<udid>); <name> (<udid>)".
                let formatted = udids.map { udid -> String in
                    if let name = names[udid] { return "\(name) (\(udid))" }
                    return udid
                }.joined(separator: "; ")
                return "Multiple simulators are booted (\(udids.count)): \(formatted). Pass `--device <UDID>` or set the SIM_USE_DEVICE environment variable to disambiguate."
            case .simctlFailed(let message):
                return "Failed to list booted simulators via simctl: \(message). Pass `--device <UDID>` explicitly to skip auto-resolution."
            case .conflictingEnvVars:
                return "Both SIM_USE_DEVICE and SIM_USE_UDID are set. Unset one — they are aliases."
            }
        }

        public var hint: String? {
            switch self {
            case .noSimulatorBooted, .simctlFailed, .conflictingEnvVars:
                return nil
            case .multipleSimulatorsBooted(let udids, let names):
                let pairs = udids.map { udid -> String in
                    if let name = names[udid] { return "\(name) (\(udid))" }
                    return udid
                }
                return "booted simulators: \(pairs.joined(separator: "; "))"
            }
        }
    }

    /// Source of booted-simulator information. Prod uses `simctl`; tests
    /// inject a fixture closure so the resolver can be unit-tested without
    /// a real Xcode toolchain on the box.
    public typealias BootedListProvider = () throws -> [BootedSimulator]

    public struct BootedSimulator: Equatable {
        public let udid: String
        public let name: String

        public init(udid: String, name: String) {
            self.udid = udid
            self.name = name
        }
    }

    public static func resolve(
        explicit: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        baseDirectory: URL? = nil,
        bootedListProvider: BootedListProvider = simctlBootedListProvider
    ) throws -> String {
        // 1. Explicit --device / --udid wins, after a trim so a stray
        // space doesn't accidentally bypass auto-resolution.
        if let explicit, !explicit.trimmingCharacters(in: .whitespaces).isEmpty {
            return explicit.trimmingCharacters(in: .whitespaces)
        }

        // 2. Per-shell override. SIM_USE_DEVICE is preferred; SIM_USE_UDID
        // remains accepted as a deprecated alias. Setting both is a
        // fast-fail so we never silently pick one over the other.
        let envDevice = environment["SIM_USE_DEVICE"]?
            .trimmingCharacters(in: .whitespaces)
            .nonEmptyOrNil
        let envUDID = environment["SIM_USE_UDID"]?
            .trimmingCharacters(in: .whitespaces)
            .nonEmptyOrNil
        if envDevice != nil && envUDID != nil {
            throw ResolutionError.conflictingEnvVars
        }
        if let env = envDevice ?? envUDID {
            return env
        }

        // 3. Single live daemon — steady-state fast path. After the first
        // command in an agent session this hits and avoids the simctl fork.
        // A base directory that fails validation throws here: resolution
        // must not be steered by forged pidfiles in a pre-planted tree.
        let daemons = try DaemonPaths.enumerateLiveDaemons(baseDirectory: baseDirectory)
        if daemons.count == 1 {
            return daemons[0].udid
        }

        // 4. Cold path: ask simctl. The provider is injectable so tests
        // do not need an Xcode toolchain on the box.
        let booted: [BootedSimulator]
        do {
            booted = try bootedListProvider()
        } catch let error as ResolutionError {
            throw error
        } catch {
            throw ResolutionError.simctlFailed(message: error.localizedDescription)
        }

        switch booted.count {
        case 1:
            return booted[0].udid
        case 0:
            throw ResolutionError.noSimulatorBooted
        default:
            let names = Dictionary(uniqueKeysWithValues: booted.map { ($0.udid, $0.name) })
            throw ResolutionError.multipleSimulatorsBooted(
                udids: booted.map(\.udid),
                names: names
            )
        }
    }

    /// Production booted-list provider. Spawns `xcrun simctl list devices
    /// booted -j` and parses the JSON. Errors map to `ResolutionError.simctlFailed`.
    public static let simctlBootedListProvider: BootedListProvider = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "booted", "-j"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ResolutionError.simctlFailed(message: "could not spawn simctl: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ResolutionError.simctlFailed(
                message: "simctl exited \(process.terminationStatus): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return try parseSimctlBootedJSON(data)
    }

    /// Append `--device <value>` to `args` when neither `--device` nor
    /// `--udid` (with or without the `=value` form) is already present.
    /// Used by the client-side `run()` to forward the resolved device id
    /// across the daemon socket so the daemon-side parse sees an
    /// explicit value (the daemon process cannot rely on the same
    /// single-booted-simulator contract the client used to resolve in
    /// the first place). Idempotent.
    ///
    /// Forwards as `--device` (the new canonical name). Daemon binaries
    /// built before `--device` was accepted must be restarted
    /// (`sim-use daemon stop`) after the client upgrade so the daemon
    /// process picks up the new parser.
    public static func injectingDeviceIfNeeded(_ args: [String], device: String) -> [String] {
        if args.contains("--device") || args.contains("--udid") { return args }
        if args.contains(where: { $0.hasPrefix("--device=") || $0.hasPrefix("--udid=") }) {
            return args
        }
        return args + ["--device", device]
    }

    /// Parses the JSON shape emitted by `simctl list devices booted -j`:
    ///
    ///   { "devices": { "<runtime>": [ { "udid": "...", "name": "...", ... }, ... ], ... } }
    ///
    /// Only `state == "Booted"` devices show up under `booted`, so we
    /// flatten across runtimes and trust simctl's filter.
    public static func parseSimctlBootedJSON(_ data: Data) throws -> [BootedSimulator] {
        struct Device: Decodable {
            public let udid: String
            public let name: String
        }
        struct Envelope: Decodable {
            public let devices: [String: [Device]]
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ResolutionError.simctlFailed(message: "could not parse simctl JSON: \(error.localizedDescription)")
        }

        return envelope.devices
            .values
            .flatMap { $0 }
            .map { BootedSimulator(udid: $0.udid, name: $0.name) }
            .sorted { $0.udid < $1.udid }
    }
}

extension String {
    fileprivate var nonEmptyOrNil: String? { isEmpty ? nil : self }
}