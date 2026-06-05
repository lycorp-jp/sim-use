// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Line-delimited JSON protocol spoken between the daemon server and its
/// clients. The same envelope shape is reused for the `--json` flag so
/// agents consuming CLI output and agents talking to the daemon share a
/// single parser.
///
/// Wire framing: one JSON object per line, terminated by `\n`. No length
/// prefix, no multiplexing in v1 — clients send one request at a time and
/// read until newline for the matching response.
public enum DaemonProtocol {
    public static let version: Int = 1

    public enum ManagementCommand: String {
        case ping = "_ping"
        case stop = "_stop"
    }
}

public struct DaemonRequest: Codable {
    public let id: String?
    public let cmd: String
    public let args: [String]

    public init(id: String? = nil, cmd: String, args: [String] = []) {
        self.id = id
        self.cmd = cmd
        self.args = args
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.cmd = try container.decode(String.self, forKey: .cmd)
        self.args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let id { try container.encode(id, forKey: .id) }
        try container.encode(cmd, forKey: .cmd)
        try container.encode(args, forKey: .args)
    }

    private enum CodingKeys: String, CodingKey { case id, cmd, args }
}

public struct DaemonSuccessResponse<Data: Encodable>: Encodable {
    public let id: String?
    public let ok: Bool
    public let data: Data
    /// Optional process-liveness advisory (issue #81). Additive and
    /// backward-compatible: omitted from the wire when nil, so older
    /// clients simply don't see it.
    public let advisory: ProcessAdvisory?

    public init(id: String? = nil, data: Data, advisory: ProcessAdvisory? = nil) {
        self.id = id
        self.ok = true
        self.data = data
        self.advisory = advisory
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let id { try container.encode(id, forKey: .id) }
        try container.encode(ok, forKey: .ok)
        try container.encode(data, forKey: .data)
        if let advisory, !advisory.isEmpty { try container.encode(advisory, forKey: .process) }
    }

    private enum CodingKeys: String, CodingKey { case id, ok, data, process }
}

public struct DaemonErrorResponse: Encodable {
    public let id: String?
    public let ok: Bool
    public let error: String
    public let kind: DaemonErrorKind
    public let hint: String?

    public init(
        id: String? = nil,
        error: String,
        kind: DaemonErrorKind = .other,
        hint: String? = nil
    ) {
        self.id = id
        self.ok = false
        self.error = error
        self.kind = kind
        self.hint = hint
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let id { try container.encode(id, forKey: .id) }
        try container.encode(ok, forKey: .ok)
        try container.encode(error, forKey: .error)
        try container.encode(kind, forKey: .kind)
        if let hint { try container.encode(hint, forKey: .hint) }
    }

    private enum CodingKeys: String, CodingKey { case id, ok, error, kind, hint }
}

/// Error classification that tells the client whether retry is worthwhile.
public enum DaemonErrorKind: String, Codable {
    case permanent
    case transientBooting = "transient_booting"
    case staleSimulator = "stale_simulator"
    case other

    public static func classify(_ error: Error) -> DaemonErrorKind {
        let message = error.localizedDescription
        if message.contains("as it is not booted")
            || message.contains("No translation object returned for simulator") {
            return .transientBooting
        }
        if isStaleSimulatorMessage(message) {
            return .staleSimulator
        }
        return .other
    }

    public static func isStaleSimulatorMessage(_ message: String) -> Bool {
        if message.contains("not found in set") {
            return true
        }
        if message.contains("is not booted. Current state") {
            return true
        }
        // Android: adb reports an unknown device as `adb: device 'X'
        // not found`. Without classifying this as stale, a request for
        // a bogus UDID (typo, killed emulator) spawns a daemon that
        // then survives the error and stays around as a zombie. iOS
        // already shuts the daemon down on stale handles; mirror that
        // here so the Android side has the same self-clean property.
        if message.contains("adb: device '") && message.contains("' not found") {
            return true
        }
        return false
    }
}

public struct DaemonPingData: Codable {
    public let pid: Int32
    public let uptimeSeconds: Double
    public let protocolVersion: Int
    public let simUseVersion: String
    public let udid: String

    public init(pid: Int32, uptimeSeconds: Double, protocolVersion: Int, simUseVersion: String, udid: String) {
        self.pid = pid
        self.uptimeSeconds = uptimeSeconds
        self.protocolVersion = protocolVersion
        self.simUseVersion = simUseVersion
        self.udid = udid
    }
}