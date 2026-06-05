// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Wraps `xcrun simctl list devices [booted] -j` and produces unified
/// `Device` rows for the top-level `sim-use devices` verb.
///
/// Why a separate utility from `DeviceResolver`: the resolver only ever
/// cares about *booted* sims (its job is "find the one I should talk
/// to"), so its parser drops state and runtime. The device-listing
/// verb needs both — picking a sim to interact with is a different
/// question from picking which one to boot.
public enum SimctlDeviceLister {
    public enum ListerError: Error, LocalizedError {
        case simctlFailed(message: String)

        public var errorDescription: String? {
            switch self {
            case .simctlFailed(let m): return "simctl failed: \(m)"
            }
        }
    }

    public static func listDevices(bootedOnly: Bool) throws -> [Device] {
        let data = try runSimctl(args: bootedOnly
            ? ["simctl", "list", "devices", "booted", "-j"]
            : ["simctl", "list", "devices", "-j"])
        return try parse(data)
    }

    // MARK: - Internals

    private static func runSimctl(args: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw ListerError.simctlFailed(message: "could not spawn xcrun simctl: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ListerError.simctlFailed(
                message: "xcrun simctl exited \(process.terminationStatus): \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return stdout.fileHandleForReading.readDataToEndOfFile()
    }

    /// Parses simctl's JSON:
    ///   { "devices": { "<runtimeId>": [ { "udid", "name", "state", ... }, ... ], ... } }
    ///
    /// Runtime IDs look like `com.apple.CoreSimulator.SimRuntime.iOS-18-6`.
    /// We convert them to the user-facing form `iOS 18.6` so the rendered
    /// list matches what `xcrun simctl list devices` itself prints.
    public static func parse(_ data: Data) throws -> [Device] {
        struct RawDevice: Decodable {
            public let udid: String
            public let name: String
            public let state: String
        }
        struct Envelope: Decodable {
            public let devices: [String: [RawDevice]]
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ListerError.simctlFailed(message: "could not parse simctl JSON: \(error.localizedDescription)")
        }

        var devices: [Device] = []
        for (runtimeId, raws) in envelope.devices {
            let runtime = friendlyRuntime(runtimeId)
            for raw in raws {
                devices.append(Device(
                    udid: raw.udid,
                    name: raw.name,
                    platform: .ios,
                    state: raw.state,
                    runtime: runtime
                ))
            }
        }
        // Stable order: by platform/runtime/name/udid so two runs against
        // the same set of sims produce identical output. `Device` doesn't
        // implement `Comparable` so build the key inline.
        devices.sort { a, b in
            if a.runtime != b.runtime { return (a.runtime ?? "") < (b.runtime ?? "") }
            if a.name != b.name       { return a.name < b.name }
            return a.udid < b.udid
        }
        return devices
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-18-6` → `iOS 18.6`.
    /// Unknown shapes fall back to the original identifier so we never
    /// silently lose information.
    public static func friendlyRuntime(_ identifier: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard identifier.hasPrefix(prefix) else { return identifier }
        let tail = String(identifier.dropFirst(prefix.count))
        // Tail is e.g. `iOS-18-6` or `watchOS-26-1` or
        // `tvOS-26-2`. First `-` separates family from version; the
        // remaining `-`s are version separators that should become `.`.
        guard let firstDash = tail.firstIndex(of: "-") else { return tail }
        let family = String(tail[..<firstDash])
        let version = tail[tail.index(after: firstDash)...].replacingOccurrences(of: "-", with: ".")
        return "\(family) \(version)"
    }
}