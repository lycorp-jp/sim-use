// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl
import SimUseCore

/// iOS Simulator backend for the `paste` verb. Mirrors the flag
/// surface of top-level `Paste` and is also reachable directly as
/// `sim-use ios paste`. The top-level command resolves the target
/// platform via `PlatformRouter` and forwards iOS UDIDs through here.
///
/// Supports both the default HID Cmd+V path and `--via-menu` (touch
/// long-press + edit-menu Paste). `--via-menu` is iOS-only — on
/// Android the bridge already bypasses the IME via ACTION_PASTE.
public struct IOSSimPasteCommand: SimUseExecutableCommand {
    public struct ExecutionResult: Codable {
        public init() {}
    }

    public static let configuration = CommandConfiguration(
        commandName: "paste",
        abstract: "Paste text into the focused field via the simulator pasteboard (bypasses IME).",
        discussion: """
        Writes the text to the simulator pasteboard with `simctl pbcopy` and
        triggers Cmd+V. Characters reach the responder chain without going
        through the keyboard, so IME composition (e.g. Japanese kana) cannot
        munge ASCII input and arbitrary Unicode is safe.

        Two input delivery paths:

        1. DEFAULT (Cmd+V via HID) — fast, requires a **connected hardware
           keyboard** on the simulator (Simulator.app: I/O > Keyboard >
           Connect Hardware Keyboard = ON). Under soft-keyboard-only mode
           HID key events are dropped and the paste silently no-ops.

        2. --via-menu (touch-driven) — long-press on a target field and
           tap the iOS edit-menu "Paste" button. Works regardless of the
           hardware-keyboard toggle, because no key events are involved.
           Requires --target-id <AXUniqueId> or --target-x/--target-y so
           sim-use knows where to long-press. --replace additionally taps
           "Select All" first.
        """
    )

    @Argument(help: "The text to paste. Use quotes for text with spaces or special characters.")
    public var text: String?

    @Flag(name: .customLong("stdin"), help: "Read text from standard input.")
    public var useStdin: Bool = false

    @Option(name: .customLong("file"), help: "Read text from the specified file.")
    public var inputFile: String?

    @Flag(name: .customLong("replace"), help: "Select all before pasting so the paste replaces the field's current content. Uses Cmd+A in the default path and 'Select All' in the menu path.")
    public var replace: Bool = false

    @Flag(name: .customLong("via-menu"), help: "Use the iOS edit menu (long-press → tap Paste) instead of Cmd+V. Touch-only path, works with the soft keyboard showing or hardware keyboard disconnected. Requires --target-id or --target-x/y.")
    public var viaMenu: Bool = false

    @Option(name: .customLong("target-id"), help: "For --via-menu: AXUniqueId of the field to long-press. Resolves via the live AX tree.")
    public var targetID: String?

    @Option(name: .customLong("target-x"), help: "For --via-menu: X coordinate to long-press.")
    public var targetX: Double?

    @Option(name: .customLong("target-y"), help: "For --via-menu: Y coordinate to long-press.")
    public var targetY: Double?

    @Option(name: .customLong("long-press-duration"), help: "Seconds to hold on the field for the edit menu to appear (default: 0.8).")
    public var longPressDuration: Double = 0.8

    @Option(name: .customLong("menu-timeout"), help: "Seconds to poll for the edit menu after long-press (default: 2.0).")
    public var menuTimeout: Double = 2.0

    @OptionGroup public var device: DeviceOptions

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public var daemonBypass: Bool { useStdin }

    public func format(_ result: ExecutionResult) -> CommandOutput { .empty }

    public func validate() throws {
        try Self.validateOptions(
            text: text, useStdin: useStdin, inputFile: inputFile,
            viaMenu: viaMenu,
            targetID: targetID,
            targetX: targetX, targetY: targetY
        )
    }

    /// Shared validation — input sources, empty text, and `--via-menu`
    /// target-flag consistency. Cross-platform forwarder delegates here.
    public static func validateOptions(
        text: String?,
        useStdin: Bool,
        inputFile: String?,
        viaMenu: Bool,
        targetID: String?,
        targetX: Double?,
        targetY: Double?
    ) throws {
        let sourceCount = [text != nil, useStdin, inputFile != nil].filter { $0 }.count
        if sourceCount > 1 {
            throw ValidationError("Please specify only one input source: text argument, --stdin, or --file.")
        }
        if sourceCount == 0 {
            throw ValidationError("No input provided. Provide text as argument, or use --stdin, or --file.")
        }
        if let text, text.isEmpty {
            throw ValidationError("Input text is empty; nothing to paste.")
        }

        if viaMenu {
            let hasCoord = targetX != nil && targetY != nil
            let hasID = targetID != nil
            guard hasCoord || hasID else {
                throw ValidationError("--via-menu requires a target: pass --target-id <id> or --target-x <x> --target-y <y>.")
            }
            if hasCoord && hasID {
                throw ValidationError("--via-menu accepts --target-id OR --target-x/--target-y, not both.")
            }
            if (targetX != nil) != (targetY != nil) {
                throw ValidationError("--target-x and --target-y must be supplied together.")
            }
        } else if targetID != nil || targetX != nil || targetY != nil {
            throw ValidationError("--target-id / --target-x / --target-y are only valid with --via-menu.")
        }
    }

    // HID Cmd+V is silently dropped while the simulator's software
    // keyboard is taking input (ConnectHardwareKeyboard = OFF). That's
    // the #1 "paste did nothing" failure in practice, so the client
    // process runs a cheap AX-tree probe and prints a pointed stderr
    // hint before dispatching. Skipped for --via-menu (which is
    // hardware-keyboard-independent) and for --json (so machine-parsed
    // output stays clean — scripts can call `sim-use keyboard-state`
    // if they need a structured signal).
    public func clientPreflight() async {
        guard !viaMenu, !jsonOutput else { return }
        do {
            let logger = SimUseLogger()
            try await setup(logger: logger)
            let state = try await SoftKeyboardDetector.detect(for: device.resolved, logger: logger)
            guard state.visible else { return }
            let hint = """
                warning: soft keyboard detected on simulator \
                (chrome=\(state.chromeKeyCount), letters=\(state.letterKeyCount)); \
                HID Cmd+V is dropped in this mode and the paste will silently \
                no-op. Prefer `sim-use paste --via-menu --target-id <id>` (touch path), \
                or connect the simulator hardware keyboard \
                (Simulator.app: I/O > Keyboard > Connect Hardware Keyboard).
                """
            FileHandle.standardError.write(Data((hint + "\n").utf8))
        } catch {
            // Silent: detection must never block the actual paste.
        }
    }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let inputText = try resolveInputText(logger: logger)
        guard !inputText.isEmpty else {
            throw CLIError(errorDescription: "Input text is empty; nothing to paste.")
        }

        logger.info().log("Writing \(inputText.utf8.count) byte(s) to simulator pasteboard")
        try Self.writeSimulatorPasteboard(text: inputText, udid: device.resolved)

        if viaMenu {
            let (target, calibration) = try await resolveTargetPoint(logger: logger)
            try await pasteViaEditMenu(at: target, calibration: calibration, logger: logger)
        } else {
            if replace {
                logger.info().log("--replace: sending Cmd+A to select all")
                try await sendModifierCombo(key: PasteHIDKeycode.a, modifier: PasteHIDKeycode.leftGUI, logger: logger)
            }
            logger.info().log("Sending Cmd+V to paste")
            try await sendModifierCombo(key: PasteHIDKeycode.v, modifier: PasteHIDKeycode.leftGUI, logger: logger)
        }

        logger.info().log("Paste completed successfully")
        return ExecutionResult()
    }

    // MARK: - Edit-menu paste path

    /// Returns the long-press point in HID (framebuffer) space plus the
    /// orientation calibration when one was computed. Explicit
    /// `--target-x/y` stays raw by the same contract as `tap -x/-y`;
    /// `--id` resolves through the AX tree (UI space) and must be
    /// transformed (issue #34).
    private func resolveTargetPoint(logger: SimUseLogger) async throws -> ((x: Double, y: Double), OrientationCalibration?) {
        if let x = targetX, let y = targetY {
            return ((x, y), nil)
        }
        guard let targetID else {
            throw CLIError(errorDescription: "Internal: --via-menu reached execute without a target.")
        }
        let hidTarget = try await AccessibilityPoller.resolveWithPollingHIDTarget(
            query: .id(targetID),
            simulatorUDID: device.resolved,
            waitTimeout: 0,
            pollInterval: 0.25,
            elementType: nil,
            logger: logger
        )
        return (hidTarget.hid, hidTarget.calibration)
    }

    private func pasteViaEditMenu(
        at target: (x: Double, y: Double),
        calibration: OrientationCalibration?,
        logger: SimUseLogger
    ) async throws {
        logger.info().log("long-press at (\(target.x),\(target.y))")
        try await longPress(at: target, logger: logger)

        if replace {
            try await tapEditMenuItem(labels: Self.selectAllLabels, kind: "Select All", calibration: calibration, logger: logger)
            do {
                try await tapEditMenuItem(
                    labels: Self.pasteMenuLabels,
                    kind: "Paste",
                    calibration: calibration,
                    logger: logger,
                    timeout: 1.0
                )
            } catch {
                logger.info().log("Paste menu did not re-appear after Select All; re-long-pressing to re-invoke")
                try await longPress(at: target, logger: logger)
                try await tapEditMenuItem(labels: Self.pasteMenuLabels, kind: "Paste", calibration: calibration, logger: logger)
            }
        } else {
            try await tapEditMenuItem(labels: Self.pasteMenuLabels, kind: "Paste", calibration: calibration, logger: logger)
        }
    }

    private func longPress(at point: (x: Double, y: Double), logger: SimUseLogger) async throws {
        let durationNs = UInt64(max(0.1, longPressDuration) * 1_000_000_000)
        let down = FBSimulatorHIDEvent.touchDownAt(x: point.x, y: point.y)
        let up = FBSimulatorHIDEvent.touchUpAt(x: point.x, y: point.y)
        try await HIDInteractor.performHIDEvent(down, for: device.resolved, logger: logger)
        try await Task.sleep(nanoseconds: durationNs)
        try await HIDInteractor.performHIDEvent(up, for: device.resolved, logger: logger)
    }

    private func tapEditMenuItem(
        labels: Set<String>,
        kind: String,
        calibration: OrientationCalibration?,
        logger: SimUseLogger,
        timeout: Double? = nil
    ) async throws {
        let effectiveTimeout = timeout ?? menuTimeout
        let deadline = Date().addingTimeInterval(effectiveTimeout)
        let pollInterval: UInt64 = 120_000_000

        while Date() < deadline {
            let elements = try await fetchLightweightTree(logger: logger)
            let flat = elements.flatMap { $0.flattened() }
            if let match = flat.first(where: { el in
                guard let label = el.normalizedLabel else { return false }
                return labels.contains(label)
            }), let frame = match.frame, frame.width > 0, frame.height > 0 {
                let x = frame.x + frame.width / 2.0
                let y = frame.y + frame.height / 2.0
                // Menu-item centers come from the AX tree (UI space).
                // Reuse the target resolution's calibration; the
                // explicit --target-x/y path never calibrated, so probe
                // now against the tree that contains the match.
                let effective: OrientationCalibration
                if let calibration {
                    effective = calibration
                } else {
                    effective = await OrientationCalibrator.calibrate(udid: device.resolved, roots: elements, logger: logger)
                }
                let hid = effective.hidPoint(x: x, y: y)
                logger.info().log("Tapping '\(match.normalizedLabel ?? "?")' (\(kind)) at (\(x),\(y))")
                let tap = FBSimulatorHIDEvent.tapAt(x: hid.x, y: hid.y)
                try await HIDInteractor.performHIDEvent(tap, for: device.resolved, logger: logger)
                return
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
        throw CLIError(errorDescription: "Edit menu '\(kind)' item did not appear within \(effectiveTimeout)s. The field may not support the iOS edit menu, or long-press missed the target.")
    }

    private func fetchLightweightTree(logger: SimUseLogger) async throws -> [AccessibilityElement] {
        let jsonData = try await AccessibilityFetcher.fetchAccessibilityInfoJSONData(
            for: device.resolved,
            point: nil,
            logger: logger,
            maxProbes: 0
        )
        let decoder = JSONDecoder()
        do {
            return try decoder.decode([AccessibilityElement].self, from: jsonData)
        } catch let DecodingError.typeMismatch(_, context) where context.codingPath.isEmpty {
            return [try decoder.decode(AccessibilityElement.self, from: jsonData)]
        }
    }

    private static let pasteMenuLabels: Set<String> = [
        "Paste", "粘贴", "貼上", "ペースト", "붙여넣기",
        "Einsetzen", "Coller", "Pegar", "Incolla",
    ]

    private static let selectAllLabels: Set<String> = [
        "Select All", "全选", "全選", "すべて選択", "전체 선택",
        "Alles auswählen", "Tout sélectionner",
        "Seleccionar todo", "Seleziona tutto",
    ]

    // MARK: - Input resolution

    private func resolveInputText(logger: SimUseLogger) throws -> String {
        try Self.resolveInputText(
            text: text, useStdin: useStdin, inputFile: inputFile,
            logger: logger
        )
    }

    /// Shared input resolver used by the top-level forwarder so both
    /// surfaces collect text identically before dispatch.
    public static func resolveInputText(
        text: String?,
        useStdin: Bool,
        inputFile: String?,
        logger: SimUseLogger?
    ) throws -> String {
        switch (text, useStdin, inputFile) {
        case (let positional?, false, nil):
            return positional
        case (nil, true, nil):
            logger?.info().log("Reading text from standard input...")
            var input = ""
            while let line = readLine(strippingNewline: false) {
                input += line
            }
            return input
        case (nil, false, let file?):
            logger?.info().log("Reading text from file: \(file)")
            do {
                return try String(contentsOfFile: file, encoding: .utf8)
            } catch {
                throw ValidationError("Failed to read file '\(file)': \(error.localizedDescription)")
            }
        default:
            throw ValidationError("Invalid input configuration.")
        }
    }

    // MARK: - Pasteboard write

    /// Run `simctl pbcopy` to write the simulator pasteboard. Exposed
    /// `static` so the `paste` batch step (BatchConvertible) can reuse
    /// the same path without spinning up a fresh command instance.
    public static func writeSimulatorPasteboard(text: String, udid: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "pbcopy", udid]

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try process.run()
        if let data = text.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw CLIError(errorDescription: "simctl pbcopy failed (exit \(process.terminationStatus)): \(message)")
        }
    }

    // MARK: - HID combo

    private func sendModifierCombo(key: UInt32, modifier: UInt32, logger: SimUseLogger) async throws {
        let events: [FBSimulatorHIDEvent] = [
            FBSimulatorHIDEvent.keyDown(modifier),
            FBSimulatorHIDEvent.shortKeyPress(key),
            FBSimulatorHIDEvent.keyUp(modifier),
        ]
        let combo = FBSimulatorHIDEvent(events: events)
        try await HIDInteractor.performHIDEvent(combo, for: device.resolved, logger: logger)
    }
}

/// Inlined HID keycodes for the paste-related Cmd combos. Public so
/// the `paste` batch step (`BatchConvertible`) can emit the same HID
/// shape without depending on the larger keycode table.
public enum PasteHIDKeycode {
    public static let a: UInt32 = 4
    public static let v: UInt32 = 25
    public static let leftGUI: UInt32 = 227
}