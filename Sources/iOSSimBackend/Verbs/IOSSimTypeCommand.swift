// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl
import SimUseCore

/// iOS Simulator backend for the `type` verb. Mirrors the flag
/// surface of top-level `Type` and is also reachable directly as
/// `sim-use ios type`. The top-level command resolves the target
/// platform via `PlatformRouter` and forwards iOS UDIDs through here.
public struct IOSSimTypeCommand: SimUseExecutableCommand {
    public struct ExecutionResult: Codable {
        public init() {}
    }

    public static let configuration = CommandConfiguration(
        commandName: "type",
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
    public var text: String?

    @Flag(name: .customLong("stdin"), help: "Read text from standard input.")
    public var useStdin: Bool = false

    @Option(name: .customLong("file"), help: "Read text from the specified file.")
    public var inputFile: String?

    @OptionGroup public var device: DeviceOptions

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    // The daemon runs with stdin=/dev/null, so --stdin input would read
    // zero bytes through the daemon path. Bypass the daemon only when
    // reading from stdin; positional and --file inputs go through the
    // daemon as usual.
    public var daemonBypass: Bool { useStdin }

    public func format(_ result: ExecutionResult) -> CommandOutput { .empty }

    public func validate() throws {
        try Self.validateOptions(text: text, useStdin: useStdin, inputFile: inputFile)
    }

    /// Shared input-source validation. The top-level cross-platform
    /// forwarder delegates here so the rules stay in one place.
    public static func validateOptions(
        text: String?,
        useStdin: Bool,
        inputFile: String?
    ) throws {
        let sourceCount = [text != nil, useStdin, inputFile != nil].filter { $0 }.count
        if sourceCount > 1 {
            throw ValidationError("Please specify only one input source: text argument, --stdin, or --file.")
        }
        if sourceCount == 0 {
            throw ValidationError("No input provided. Provide text as argument, or use --stdin, or --file.")
        }
    }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let inputText: String
        switch (text, useStdin, inputFile) {
        case (let positional?, false, nil):
            inputText = positional
            logger.info().log("Using positional text input: '\(inputText)'")
        case (nil, true, nil):
            logger.info().log("Reading text from standard input...")
            inputText = Self.readFromStdin()
            logger.info().log("Read from stdin: '\(inputText)'")
        case (nil, false, let file?):
            logger.info().log("Reading text from file: \(file)")
            inputText = try Self.readFromFile(file)
            logger.info().log("Read from file: '\(inputText)'")
        case (nil, false, nil):
            // CLIError on the execute() path — validate() catches the
            // same condition with ValidationError (ArgumentParser
            // renders that correctly with the "Usage:" line) but the
            // daemon dispatch path skips validate(), so a defence-in-
            // depth ValidationError here would surface as the opaque
            // "(ArgumentParser.ValidationError error 1.)" wrapper.
            throw CLIError(errorDescription: "No input provided. Provide text as argument, or use --stdin, or --file.")
        default:
            throw CLIError(errorDescription: "Invalid input configuration.")
        }

        guard TextToHIDEvents.validateText(inputText) else {
            let unsupportedChars = inputText.compactMap { char -> Character? in
                let keyEvent = KeyEvent.keyCodeForString(String(char))
                return keyEvent.keyCode == 0 ? char : nil
            }
            let errorMessage = """
                Unsupported characters found: \(unsupportedChars.map { "'\($0)'" }.joined(separator: ", "))

                Only US keyboard characters are supported via HID keycodes.
                Supported: A-Z, a-z, 0-9, and symbols: !@#$%^&*()_+-={}[]|\\:";'<>?,./`~
                """
            logger.error().log(errorMessage)
            throw TextToHIDEvents.TextConversionError.unsupportedCharacter(unsupportedChars.first!)
        }

        let hidEvents: [FBSimulatorHIDEvent]
        do {
            hidEvents = try TextToHIDEvents.convertTextToHIDEvents(inputText)
            logger.info().log("Successfully converted text to \(hidEvents.count) HID events")
        } catch let error as TextToHIDEvents.TextConversionError {
            logger.error().log("Text conversion failed: \(error.localizedDescription)")
            throw error
        } catch {
            logger.error().log("Unexpected error during text conversion: \(error.localizedDescription)")
            throw error
        }

        // Empty input yields zero HID events. Return before building a
        // session so `type ""` stays a strict no-op — it must not pay
        // framework/simulator-set initialisation or fail against a
        // device that is not booted (an agent's `type "$VAR"` with an
        // empty variable relied on the pre-session-reuse behaviour).
        guard !hidEvents.isEmpty else {
            logger.info().log("No HID events to perform (empty input); skipping session.")
            return ExecutionResult()
        }

        logger.info().log("Performing HID event sequence for text typing")

        // One session for the whole string: the per-UDID overload runs
        // makeSession (framework load + FBSimulatorControl set
        // construction) on every call, which multiplies per character
        // typed. Only the HID connection inside is cached.
        let session = try await HIDInteractor.makeSession(for: device.resolved, logger: logger)
        for event in hidEvents {
            try await HIDInteractor.performHIDEvent(
                event,
                in: session,
                logger: logger
            )
        }

        logger.info().log("Text typing completed successfully")
        return ExecutionResult()
    }

    /// Shared stdin reader. Public so the top-level forwarder can
    /// collect text the same way before routing to either backend.
    public static func readFromStdin() -> String {
        var input = ""
        while let line = readLine() {
            if !input.isEmpty {
                input += "\n"
            }
            input += line
        }
        return input
    }

    /// Shared file reader. Public so the top-level forwarder shares
    /// the same error surface (`CLIError` wrapping the underlying
    /// file-read error). CLIError, not ArgumentParser.ValidationError,
    /// because this is invoked from `execute()` whose error path is
    /// our run() catch — see IOSSimKeyCommand for the rationale.
    public static func readFromFile(_ filePath: String) throws -> String {
        do {
            return try String(contentsOfFile: filePath, encoding: .utf8)
        } catch {
            throw CLIError(errorDescription: "Failed to read file '\(filePath)': \(error.localizedDescription)")
        }
    }
}