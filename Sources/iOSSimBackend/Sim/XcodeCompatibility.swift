// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Xcode-version compatibility checks for the iOS-Simulator HID pipeline.
///
/// Xcode 27 removed `SimulatorKit.framework` (the simulator stack was
/// folded into the relocated system `CoreSimulator` plus the new DeviceHub
/// app), so the private-framework load the HID pipeline depends on fails
/// with a cryptic dyld "does not exist". We detect the missing framework up
/// front and surface an actionable message pointing at Xcode 26.x.
///
/// Tracking issue: Xcode 27 support
/// (github.com/lycorp-jp/sim-use/issues/84).
enum XcodeCompatibility {
    /// Throws an actionable `CLIError` when the selected Xcode does not ship
    /// `SimulatorKit.framework` (i.e. Xcode 27+). No-op otherwise, including
    /// when the developer directory cannot be resolved (let the downstream
    /// loader produce its own error in that case).
    static func assertSimulatorKitAvailable(logger: SimUseLogger) throws {
        guard let developerDir = selectedDeveloperDir() else { return }
        let simulatorKit = developerDir + "/Library/PrivateFrameworks/SimulatorKit.framework"
        if FileManager.default.fileExists(atPath: simulatorKit) { return }

        let message = """
            SimulatorKit.framework is not present in the selected Xcode:
              \(developerDir)
            Xcode 27 removed SimulatorKit; sim-use's iOS Simulator HID pipeline
            requires Xcode 26.x. Point xcode-select at an Xcode 26.x install, e.g.:
              sudo xcode-select -s /Applications/Xcode.app
            then retry. (Tracking: Xcode 27 support, issue #84.)
            """
        logger.error().log(message)
        throw CLIError(errorDescription: message)
    }

    /// The active `xcode-select` developer directory, preferring an explicit
    /// `DEVELOPER_DIR` override. Returns nil if it cannot be determined.
    private static func selectedDeveloperDir() -> String? {
        if let dir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !dir.isEmpty {
            return dir
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty
        else {
            return nil
        }
        return output
    }
}