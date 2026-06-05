// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend

/// Top-level cross-platform `type` verb. Owns the flag surface and
/// resolves the target platform, then delegates to the per-backend
/// command (`IOSSimTypeCommand` for iOS Simulator UDIDs,
/// `AndroidTypeCommand.performType` for adb serials).
///
/// Android dispatch defaults to `clear: false` (append at caret) so
/// it matches iOS HID's natural append behaviour. Callers wanting
/// replace-mode on Android should use `sim-use android type --clear`
/// directly.
struct Type: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimTypeCommand.ExecutionResult

    static let configuration = CommandConfiguration(
        abstract: "Type text by entering a sequence of characters.",
        discussion: """
        Input Methods:
        1. Direct text: sim-use type "Hello World" --udid UDID
        2. From stdin: echo "Hello World!" | sim-use type --stdin --udid UDID
        3. From file: sim-use type --file text.txt --udid UDID

        Examples:
        • Simple text: sim-use type "Hello World" --udid UDID
        • With spaces: sim-use type "Hello, how are you?" --udid UDID
        • Special characters: sim-use type 'Hello!' --udid UDID

        Shell Escaping Tips:
        • Use double quotes for text with spaces: "Hello World"
        • Use single quotes for text with special characters: 'Hello!'
        • For complex text or automation, prefer --stdin or --file methods

        Character Support:
        • Only US keyboard characters are supported via HID keycodes
        • Supported: A-Z, a-z, 0-9, and symbols: !@#$%^&*()_+-={}[]|\\:";'<>?,./`~
        • Not supported: International characters (£€¥), accented letters (éñü), etc.
        • This is a limitation of the underlying HID keyboard protocol

        Note: iOS may apply smart punctuation spacing to some characters.
        """
    )

    @Argument(help: "The text to type. Use quotes for text with spaces or special characters.")
    var text: String?

    @Flag(name: .customLong("stdin"), help: "Read text from standard input.")
    var useStdin: Bool = false

    @Option(name: .customLong("file"), help: "Read text from the specified file.")
    var inputFile: String?

    @OptionGroup var device: DeviceOptions

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    // The daemon runs with stdin=/dev/null. Bypass daemon when reading
    // from stdin so --stdin actually sees the caller's terminal input.
    var daemonBypass: Bool { useStdin }

    func format(_ result: ExecutionResult) -> CommandOutput { .empty }

    func validate() throws {
        try IOSSimTypeCommand.validateOptions(text: text, useStdin: useStdin, inputFile: inputFile)
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
        var sub = IOSSimTypeCommand()
        sub.text = text
        sub.useStdin = useStdin
        sub.inputFile = inputFile
        sub.device = device
        sub.json = json
        return try await sub.execute()
    }

    private func executeAndroid() throws -> ExecutionResult {
        let inputText: String
        switch (text, useStdin, inputFile) {
        case (let positional?, false, nil):
            inputText = positional
        case (nil, true, nil):
            inputText = IOSSimTypeCommand.readFromStdin()
        case (nil, false, let file?):
            inputText = try IOSSimTypeCommand.readFromFile(file)
        case (nil, false, nil):
            throw ValidationError("No input provided. Provide text as argument, or use --stdin, or --file.")
        default:
            throw ValidationError("Invalid input configuration.")
        }
        try AndroidTypeCommand.performType(udid: device.resolved, text: inputText, clear: false)
        return ExecutionResult()
    }
}