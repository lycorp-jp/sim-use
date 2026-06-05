// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use android devices` — list attached Android devices /
/// emulators. Preserved alongside the cross-platform `sim-use devices`
/// for scripts that already pin to the explicit Android form.
public struct AndroidDevicesCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List attached Android devices / emulators.",
        discussion: """
        Tip: `sim-use devices` is the cross-platform replacement and
        emits the same JSON envelope shape covering both iOS Simulators
        and Android devices. This subcommand is preserved for scripts
        already pinning to it.
        """
    )

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {devices: [...]}}` envelope used by `sim-use devices --json`.")
    public var jsonOutput: Bool = false

    public init() {}

    /// Tabular row carrying just the fields the human-readable Android
    /// listing exposes (model / product / state). Kept Codable so
    /// `ExecutionResult` can satisfy the protocol contract, but the
    /// JSON envelope shape uses `devices` (the unified cross-platform
    /// rows) — this auxiliary array stays out of the wire via
    /// `CodingKeys`. It exists so the text-mode formatter can rebuild
    /// the historical `serial<TAB>state<TAB>model=…<TAB>product=…`
    /// table without re-querying adb.
    public struct AdbRow: Codable {
        public let serial: String
        public let state: String
        public let model: String?
        public let product: String?
    }

    public struct ExecutionResult: Codable {
        public let devices: [Device]
        public let adbRows: [AdbRow]

        private enum CodingKeys: String, CodingKey { case devices }

        public init(devices: [Device], adbRows: [AdbRow]) {
            self.devices = devices
            self.adbRows = adbRows
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.devices = try container.decode([Device].self, forKey: .devices)
            self.adbRows = []
        }
    }

    // `devices` has no UDID input — nothing for the daemon to scope
    // against. Bypass naturally via nil here; the protocol-default
    // `run()` falls through to in-process execution.
    public var simulatorUDIDForDaemon: String? { nil }

    public func execute() async throws -> ExecutionResult {
        let controller = AndroidDeviceController()
        if jsonOutput {
            // JSON consumers only need the unified rows; skip the raw
            // `adb devices -l` parse entirely so we don't pay for
            // model/product attributes that won't be emitted.
            return ExecutionResult(devices: try controller.listUnifiedDevices(), adbRows: [])
        }
        let rows = try controller.listDevices().map { row in
            AdbRow(serial: row.serial, state: row.state, model: row.model, product: row.product)
        }
        return ExecutionResult(devices: [], adbRows: rows)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        if result.adbRows.isEmpty {
            return .line("No Android devices attached.")
        }
        let lines = result.adbRows.map { row -> String in
            let model = row.model ?? "?"
            let product = row.product ?? "?"
            return "\(row.serial)\t\(row.state)\tmodel=\(model)\tproduct=\(product)"
        }
        return .lines(lines)
    }
}