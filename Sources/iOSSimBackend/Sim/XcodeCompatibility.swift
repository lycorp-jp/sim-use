// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Xcode-version compatibility checks for the iOS-Simulator HID pipeline.
///
/// Xcode 27 moved `SimulatorKit.framework` out of
/// `Contents/Developer/Library/PrivateFrameworks/` (its home through
/// Xcode 26) into `Contents/SharedFrameworks/`; early Xcode 27 betas
/// shipped without it entirely. When it is absent from both locations the
/// private-framework load the HID pipeline depends on fails with a cryptic
/// dyld "does not exist", so we detect that up front and surface an
/// actionable message.
///
/// Work record: docs/ai/xxxx-xcode27-support/README.md.
enum XcodeCompatibility {
    /// Throws an actionable `CLIError` when the selected Xcode does not ship
    /// `SimulatorKit.framework` at any known location. No-op otherwise,
    /// including when the developer directory cannot be resolved (let the
    /// downstream loader produce its own error in that case).
    ///
    /// Xcode <= 26 ships it at `Developer/Library/PrivateFrameworks/`;
    /// Xcode 27 moved it to `Contents/SharedFrameworks/` (Beta 1 lacked it
    /// entirely, it returned in later betas).
    static func assertSimulatorKitAvailable(logger: SimUseLogger) throws {
        guard let developerDir = selectedDeveloperDir() else { return }
        let candidates = [
            ((developerDir as NSString)
                .appendingPathComponent("Library/PrivateFrameworks/SimulatorKit.framework") as NSString)
                .standardizingPath,
            ((developerDir as NSString)
                .appendingPathComponent("../SharedFrameworks/SimulatorKit.framework") as NSString)
                .standardizingPath,
        ]
        if candidates.contains(where: { FileManager.default.fileExists(atPath: $0) }) { return }

        let message = """
            SimulatorKit.framework is not present in the selected Xcode:
              \(developerDir)
            (checked Library/PrivateFrameworks and ../SharedFrameworks)
            sim-use's iOS Simulator HID pipeline requires an Xcode that ships
            SimulatorKit: Xcode 26.x, or an Xcode 27 build that includes it in
            Contents/SharedFrameworks (Beta 4 and later do; Beta 1 did not).
            Point xcode-select at such an install, e.g.:
              sudo xcode-select -s /Applications/Xcode.app
            then retry.
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