// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend

/// Top-level cross-platform `screenshot` verb. Owns the flag surface
/// and resolves the target platform, then delegates to the per-backend
/// command (`IOSSimScreenshotCommand` for iOS Simulator UDIDs,
/// `AndroidScreenshotCommand.performScreenshot` for adb serials).
///
/// Output path resolution differs slightly between platforms — the
/// iOS default filename embeds the FBSimulator friendly name; the
/// Android default uses the adb serial because the friendly name
/// isn't available at the bridge layer. Both honour `--output`
/// pointing at either a file or a directory.
struct Screenshot: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimScreenshotCommand.ExecutionResult

    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a screenshot from the simulator display and save it as a PNG file"
    )

    @OptionGroup var device: DeviceOptions

    @Option(help: "Output PNG file path. Defaults to 'Simulator Screenshot - <device name> - <timestamp>.png' in the current directory.")
    var output: String?

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    var daemonBypass: Bool { true }

    func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(
            stdout: result.path + "\n",
            stderr: "Screenshot saved to \(result.path)\n"
        )
    }

    func execute() async throws -> ExecutionResult {
        switch PlatformRouter.resolve(udid: device.resolved) {
        case .android:
            return try executeAndroid()
        case .iOSSim, .none:
            return try await executeIOSSim()
        }
    }

    private func executeIOSSim() async throws -> ExecutionResult {
        var sub = IOSSimScreenshotCommand()
        sub.output = output
        sub.device = device
        sub.json = json
        return try await sub.execute()
    }

    private func executeAndroid() throws -> ExecutionResult {
        let png = try AndroidScreenshotCommand.performScreenshot(udid: device.resolved)
        let path = resolveAndroidOutputPath(serial: device.resolved)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
        return ExecutionResult(path: url.path)
    }

    private func resolveAndroidOutputPath(serial: String) -> String {
        let stamp = IOSSimScreenshotCommand.formatTimestamp(Date())
        let defaultName = "Android Screenshot - \(serial) - \(stamp).png"
        guard let provided = output?.trimmingCharacters(in: .whitespacesAndNewlines), !provided.isEmpty else {
            return FileManager.default.currentDirectoryPath + "/" + defaultName
        }
        let expanded = (provided as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
            ? expanded
            : FileManager.default.currentDirectoryPath + "/" + expanded
        // If the user pointed `--output` at a directory (existing or
        // with a trailing slash), append the stamped filename there.
        // Otherwise treat the path as a file destination. Mirrors the
        // iOS-side `--output` behaviour where the same expansion rules
        // apply.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory)
        if (exists && isDirectory.boolValue) || absolute.hasSuffix("/") {
            let dir = absolute.hasSuffix("/") ? String(absolute.dropLast()) : absolute
            return dir + "/" + defaultName
        }
        return absolute
    }
}