// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use android ping` — bridge liveness + protocol version probe.
public struct AndroidPingCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ping",
        abstract: "Ping the device bridge to verify connection and protocol version."
    )

    @OptionGroup public var device: AndroidDeviceOptions

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {bridgeVersion, protocolVersion}}` envelope.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public let bridgeVersion: String
        public let protocolVersion: Int
    }

    /// `ping` is a diagnostic; bypass the daemon so the probe really
    /// hits the bridge instead of resolving against any cached daemon
    /// state. Mirrors the spirit of `sim-use ios ping` if it existed.
    public var daemonBypass: Bool { true }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        // Go through the registry so consecutive `sim-use android ping`
        // calls inside a single process reuse the same `BridgeClient`
        // (and therefore the same cached auth token + adb forward).
        let controller = AndroidDeviceController()
        let client = controller.bridge(serial: device.resolved)
        let ping = try client.ping()
        return ExecutionResult(bridgeVersion: ping.bridgeVersion, protocolVersion: ping.protocolVersion)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line("pong  bridge_version=\(result.bridgeVersion)  protocol_version=\(result.protocolVersion)")
    }
}