// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend

/// Cross-platform device listing. Successor to the legacy
/// `list-simulators` (iOS-only) and `android devices` verbs, which
/// remain available for now but redirect users here.
struct Devices: SimUseExecutableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List connected devices across iOS Simulators and Android devices.",
        discussion: """
        Aggregates `xcrun simctl list devices` (iOS Simulators) and
        `adb devices` (Android devices / emulators) into a single
        unified table.

        Default lists only devices sim-use can talk to right now
        (iOS `Booted`, Android `device`). Pass `--all` to include
        shutdown sims and offline / unauthorised adb entries — useful
        when picking which simulator to boot.

        Examples:
          sim-use devices                          # currently usable devices, both platforms
          sim-use devices --all                    # also include shutdown / offline
          sim-use devices --platform ios           # iOS Simulators only
          sim-use devices --json                   # structured output (Viewer, scripts, agents)

        JSON envelope (--json):
          {
            "ok": true,
            "data": {
              "devices": [
                {"deviceId": "...", "udid": "...",  // udid kept as deprecated alias of deviceId
                 "name": "...", "platform": "ios|android",
                 "state": "Booted|Shutdown|device|offline|...", "runtime": "iOS 18.6|Android|..."},
                ...
              ]
            }
          }
        """
    )

    @Flag(name: .customLong("all"), help: "Include devices that aren't currently usable (iOS Shutdown sims, Android offline / unauthorised devices). Default is booted-only.")
    var includeAll: Bool = false

    @Option(name: .customLong("platform"), help: "Restrict the list to one platform.")
    var platform: Device.Platform?

    @Flag(name: .customLong("json"), help: "Emit a JSON envelope `{ok, data: {devices: [...]}}` instead of the aligned text table.")
    var jsonOutput: Bool = false

    struct ExecutionResult: Codable {
        let devices: [Device]
    }

    func execute() async throws -> ExecutionResult {
        // Both platform queries are cheap (~50–200ms each); fire in
        // parallel so the combined latency is the slower of the two
        // rather than their sum. Errors fall through as `nil` so a
        // missing adb (Android not configured) doesn't kill iOS listing
        // and vice versa.
        async let iosFuture = listIOS()
        async let androidFuture = listAndroid()
        let iosResult = await iosFuture
        let androidResult = await androidFuture

        var combined: [Device] = []
        if platform != .android { combined.append(contentsOf: iosResult.devices) }
        if platform != .ios     { combined.append(contentsOf: androidResult.devices) }

        if !includeAll {
            combined = combined.filter { $0.isUsable }
        }

        combined.sort { lhs, rhs in
            if lhs.platform != rhs.platform { return lhs.platform.rawValue < rhs.platform.rawValue }
            if lhs.runtime != rhs.runtime   { return (lhs.runtime ?? "") < (rhs.runtime ?? "") }
            if lhs.name != rhs.name         { return lhs.name < rhs.name }
            return lhs.udid < rhs.udid
        }

        // Both sides failed and the resolved scope covered both —
        // the per-side warning above isn't enough; surface a
        // single-line summary so a user running plain `sim-use
        // devices` on a host with neither Xcode nor adb sees
        // something more actionable than "No devices found".
        if combined.isEmpty, iosResult.failed, androidResult.failed, platform == nil {
            FileHandle.standardError.write(Data(
                "warning: both iOS (simctl) and Android (adb) listings failed; pass --platform ios|android to scope, or install the missing tooling.\n".utf8
            ))
        }
        return ExecutionResult(devices: combined)
    }

    /// Each side of the parallel listing reports `(devices, failed)`
    /// rather than a bare `[Device]`. The `failed` bit lets `execute`
    /// decide whether to surface the "both lookups blew up"
    /// summary; without it the caller can't tell "Android is
    /// genuinely empty" from "adb threw before listing started".
    private struct SideResult {
        let devices: [Device]
        let failed: Bool
    }

    private func listIOS() async -> SideResult {
        // If --platform=android, skip the simctl call entirely.
        if platform == .android { return SideResult(devices: [], failed: false) }
        do {
            // We always fetch the full list (not `simctl ... booted`)
            // because the `--all` flag changes intent at runtime and
            // the cost of the wider query is small compared to the
            // process spawn itself.
            let devices = try SimctlDeviceLister.listDevices(bootedOnly: false)
            return SideResult(devices: devices, failed: false)
        } catch {
            FileHandle.standardError.write(Data("warning: iOS device listing failed: \(error.localizedDescription)\n".utf8))
            return SideResult(devices: [], failed: true)
        }
    }

    private func listAndroid() async -> SideResult {
        if platform == .ios { return SideResult(devices: [], failed: false) }
        do {
            // adb may simply be unavailable on hosts that don't do
            // Android work; that's not an error worth derailing the
            // iOS listing for.
            let devices = try AndroidDeviceController().listUnifiedDevices()
            return SideResult(devices: devices, failed: false)
        } catch {
            FileHandle.standardError.write(Data("warning: Android device listing failed: \(error.localizedDescription)\n".utf8))
            return SideResult(devices: [], failed: true)
        }
    }

    func format(_ result: ExecutionResult) -> CommandOutput {
        guard !result.devices.isEmpty else {
            return .line("No devices found. Pass --all to include shutdown / offline entries.")
        }
        return .line(renderTable(result.devices))
    }

    /// Column-aligned text table. Computed widths so an emulator serial
    /// (~14 chars) doesn't waste space alongside an iOS UDID (36).
    private func renderTable(_ devices: [Device]) -> String {
        let headers = ["PLATFORM", "STATE", "NAME", "UDID", "RUNTIME"]
        let rows: [[String]] = devices.map { d in
            [d.platform.rawValue, d.state, d.name, d.udid, d.runtime ?? "-"]
        }
        let widths: [Int] = (0..<headers.count).map { col in
            ([headers[col]] + rows.map { $0[col] }).map(\.count).max() ?? 0
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated()
                .map { i, cell in cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }
        var out = [line(headers)]
        out.append(contentsOf: rows.map(line))
        return out.joined(separator: "\n")
    }
}

extension Device.Platform: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}