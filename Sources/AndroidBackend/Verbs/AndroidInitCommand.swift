// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use android init` — install the device-bridge APK and complete
/// the bootstrap (port forward, auth token, accessibility grant).
public struct AndroidInitCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Install the sim-use device-bridge APK and complete the 6-step bootstrap on a device."
    )

    @OptionGroup public var device: AndroidDeviceOptions

    @Option(name: .customLong("apk-path"), help: "Override the bundled APK location (advanced).")
    public var apkPathOverride: String?

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {serial, bridgeVersion, protocolVersion, authTokenInstalled, portForward}}` envelope.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public let serial: String
        public let bridgeVersion: String
        public let protocolVersion: Int
        public let authTokenInstalled: Bool
        public let portForward: Int
    }

    /// `init` is a one-time bootstrap that runs before any daemon
    /// exists for this UDID. Bypass daemon so we never end up in a
    /// situation where the daemon must install the APK that the
    /// daemon itself depends on.
    public var daemonBypass: Bool { true }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        let controller = AndroidDeviceController()
        let options = AndroidDeviceController.InitOptions(apkPath: apkPathOverride)
        let report = try controller.initialize(serial: device.resolved, options: options)
        return ExecutionResult(
            serial: report.serial,
            bridgeVersion: report.bridgeVersion,
            protocolVersion: report.protocolVersion,
            authTokenInstalled: report.authTokenInstalled,
            portForward: report.portForward
        )
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .lines([
            "Bridge initialized on \(result.serial)",
            "  bridge_version    \(result.bridgeVersion)",
            "  protocol_version  \(result.protocolVersion)",
            "  auth_token        \(result.authTokenInstalled ? "ok" : "missing")",
            "  http_endpoint     localhost (forward → device tcp:\(result.portForward))",
        ])
    }
}