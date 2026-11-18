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
/// The default opens the focused field's edit menu with the HID Application
/// key, preserving its caret and selection. `--via-menu` instead long-presses
/// an explicit target. Both paths use the native Paste action, not typing.
public struct IOSSimPasteCommand: SimUseExecutableCommand {
    public struct ExecutionResult: Codable {
        public init() {}
    }

    public static let configuration = CommandConfiguration(
        commandName: "paste",
        abstract: "Paste text into the focused field via the simulator pasteboard (bypasses IME).",
        discussion: """
        Stages UTF-8 text and verifies exact clipboard readback. Uses simctl
        when its write is effective, or CoreDevice when Device Hub owns the
        clipboard. Works with Simulator.app and Device Hub, without changing
        keyboard or clipboard-sync preferences.

        By default, the target field must already be focused. The standard
        HID Application key opens its edit menu without moving the caret;
        sim-use then taps Paste. No connected hardware keyboard is required.

        --via-menu instead long-presses --target-id or --target-x/--target-y.
        Use it to focus a target explicitly or for a custom control that does
        not respond to the Application key. --replace requires Select All,
        unless accessibility confirms an empty editing control. Otherwise it
        fails before Paste instead of appending. If completion is ambiguous,
        verify the field before retrying; Paste is not automatically resent.

        Native editing rules and paste permission prompts still apply. A
        control must support the iOS edit menu. Shared clipboard sync can
        also change the Mac and other devices' clipboards. sim-use serializes
        its own paste operations, but cannot prevent other apps from copying.
        """
    )

    @Argument(help: "The text to paste. Use quotes for text with spaces or special characters.")
    public var text: String?

    @Flag(name: .customLong("stdin"), help: "Read text from standard input.")
    public var useStdin: Bool = false

    @Option(name: .customLong("file"), help: "Read text from the specified file.")
    public var inputFile: String?

    @Flag(name: .customLong("replace"), help: "Select all through the edit menu before pasting to replace the field's current content.")
    public var replace: Bool = false

    @Flag(name: .customLong("via-menu"), help: "Long-press an explicit target before native menu Paste. Requires --target-id or --target-x/y; neither mode requires a connected hardware keyboard.")
    public var viaMenu: Bool = false

    @Option(name: .customLong("target-id"), help: "For --via-menu: AXUniqueId of the field to long-press. Resolves via the live AX tree.")
    public var targetID: String?

    @Option(name: .customLong("target-x"), help: "For --via-menu: X coordinate to long-press.")
    public var targetX: Double?

    @Option(name: .customLong("target-y"), help: "For --via-menu: Y coordinate to long-press.")
    public var targetY: Double?

    @Option(name: .customLong("coordinate-space"), help: "For --target-x/--target-y: 'ui' (the default; visual space as printed by describe-ui, orientation-calibrated) or 'native' (the device's native portrait points, no calibration).")
    public var coordinateSpace: CoordinateSpace?

    /// The space `--target-x/-y` are given in.
    public var effectiveCoordinateSpace: CoordinateSpace { coordinateSpace ?? .ui }

    @Option(name: .customLong("long-press-duration"), help: "Seconds to hold on the field for the edit menu to appear (default: 0.8).")
    public var longPressDuration: Double = 0.8

    @Option(name: .customLong("menu-timeout"), help: "Seconds to wait for each edit-menu transition (default: 2.0).")
    public var menuTimeout: Double = 2.0

    @OptionGroup public var device: DeviceOptions

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func daemonArguments(from arguments: [String]) throws -> [String] {
        try Self.daemonArguments(from: arguments, useStdin: useStdin, inputFile: inputFile)
    }

    /// The daemon runs with stdin on /dev/null and in its own working
    /// directory, so `--stdin` and a relative `--file` cannot be read
    /// there. Read the text here and forward it as the positional, so the
    /// edit-menu events come from the daemon's long-lived HID
    /// connection (see `DaemonInlineInput`). Public so the top-level
    /// forwarder inlines the text the same way.
    public static func daemonArguments(from arguments: [String], useStdin: Bool, inputFile: String?) throws -> [String] {
        guard useStdin || inputFile != nil else { return arguments }
        let text: String
        do {
            text = try resolveInputText(text: nil, useStdin: useStdin, inputFile: inputFile, logger: nil)
        } catch let error as ValidationError {
            // CLIError so the message survives run()'s catch; a
            // ValidationError there degrades to the opaque bridge wrapper.
            throw CLIError(errorDescription: error.message)
        }
        return DaemonInlineInput.inliningText(text, into: arguments)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput { .empty }

    public func validate() throws {
        try Self.validateOptions(
            text: text, useStdin: useStdin, inputFile: inputFile,
            viaMenu: viaMenu,
            targetID: targetID,
            targetX: targetX, targetY: targetY,
            coordinateSpace: coordinateSpace,
            longPressDuration: longPressDuration, menuTimeout: menuTimeout
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
        targetY: Double?,
        coordinateSpace: CoordinateSpace? = nil,
        longPressDuration: Double = 0.8, menuTimeout: Double = 2
    ) throws {
        let maximumSeconds = Double(UInt64.max) / 1_000_000_000
        guard longPressDuration.isFinite, longPressDuration > 0, longPressDuration < maximumSeconds,
              menuTimeout.isFinite, menuTimeout > 0, menuTimeout < maximumSeconds else {
            throw ValidationError("Paste durations must be positive, finite and representable in nanoseconds.")
        }
        guard targetX?.isFinite != false, targetY?.isFinite != false else {
            throw ValidationError("Paste target coordinates must be finite.")
        }
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
        if let coordinateSpace, targetX == nil {
            throw ValidationError("--coordinate-space \(coordinateSpace.rawValue) applies to --target-x/--target-y only; --target-id is already resolved in ui space.")
        }
    }

    public func execute() async throws -> ExecutionResult {
        try await execute(in: nil)
    }

    func execute(in session: HIDInteractor.Session?) async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        try await RoutingDisplayGuard.assertTouchInputReachesApp(udid: device.resolved, verb: "paste", logger: logger)

        let inputText = try resolveInputText(logger: logger)
        guard !inputText.isEmpty else {
            throw CLIError(errorDescription: "Input text is empty; nothing to paste.")
        }

        let lease = try await PasteboardLock.acquire()
        defer { withExtendedLifetime(lease) {} }
        let before: [AccessibilityElement]
        if viaMenu {
            before = try await prepareEditMenu(logger: logger, session: session)
        } else {
            before = try await fetchLightweightTree(logger: logger)
        }
        try PasteEditMenu.validatePresentation(in: before)
        let existingMenu = !viaMenu && PasteEditMenu.isPresented(in: before)
        let existingActions = existingMenu ? PasteEditMenu.actionItems(in: before, excluding: []) : []
        var baseline = PasteEditMenu.items(in: before).filter { !existingActions.contains($0) }
        var emptyTargetConfirmed = false
        let target = viaMenu ? try await resolveTargetPoint(logger: logger) : nil
        try await RoutingDisplayGuard.assertTouchInputReachesApp(udid: device.resolved, verb: "paste", logger: logger)

        logger.info().log("Staging and verifying \(inputText.utf8.count) pasteboard byte(s)")
        let board = SimulatorPasteboard()
        let backend = try await board.write(text: inputText, udid: device.resolved)
        logger.info().log("Pasteboard verified through \(backend.rawValue)")
        if let target {
            try await press(at: target.0, duration: max(0.1, longPressDuration), session: session, logger: logger)
        }
        if replace {
            let current = try await prepareEditMenu(logger: logger, session: session)
            baseline = PasteEditMenu.items(in: current)
            emptyTargetConfirmed = PasteEditMenu.emptyEditingTargetConfirmed(in: current)
            // A word selection can hide Select All. Collapse it first; unlike
            // normal paste, replacement intentionally discards the old range.
            try await performHIDEvent(.shortKeyPress(PasteHIDKeycode.rightArrow), session: session, logger: logger)
            try await openFocusedEditMenu(session: session, logger: logger)
        } else if target == nil && !existingMenu {
            try await openFocusedEditMenu(session: session, logger: logger)
        }
        try await pasteViaEditMenu(
            baseline: baseline, emptyTargetConfirmed: emptyTargetConfirmed,
            calibration: target?.1, session: session,
            verify: { try await board.verify(text: inputText, udid: device.resolved, backend: backend) },
            logger: logger
        )

        logger.info().log("Paste completed successfully")
        return ExecutionResult()
    }

    // MARK: - Edit-menu paste path

    /// Returns the long-press point in HID (framebuffer) space plus the
    /// orientation calibration when one was computed. `--target-x/y`
    /// follow `tap -x/-y`: UI space unless `--coordinate-space native`;
    /// `--target-id` resolves through the AX tree (UI space) and must be
    /// transformed (issue #34).
    private func resolveTargetPoint(logger: SimUseLogger) async throws -> ((x: Double, y: Double), OrientationCalibration?) {
        if let x = targetX, let y = targetY {
            guard effectiveCoordinateSpace == .ui else { return ((x, y), nil) }
            let calibration = await UISpaceCalibrationLoader.load(
                udid: device.resolved,
                fallbackMessage: UISpaceCalibrationLoader.explicitCoordinatesFallback,
                logger: logger
            )
            return (calibration.hidPoint(x: x, y: y), calibration)
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

    private func prepareEditMenu(logger: SimUseLogger, session: HIDInteractor.Session?) async throws -> [AccessibilityElement] {
        try await PasteEditMenu.prepare(
            fetch: { try await fetchLightweightTree(logger: logger) },
            // Only replacement and explicit retargeting use this path. Ordinary
            // paste reuses the menu without touching the field or its selection.
            dismiss: { roots in
                if let target = PasteEditMenu.dismissalTarget(in: roots) {
                    try await tapMenuItem(target, roots: roots, calibration: nil, session: session, logger: logger)
                } else {
                    try await performHIDEvent(.shortKeyPress(PasteHIDKeycode.escape), session: session, logger: logger)
                    try await performHIDEvent(.shortKeyPress(PasteHIDKeycode.rightArrow), session: session, logger: logger)
                }
            },
            timeout: menuTimeout
        )
    }

    private func openFocusedEditMenu(session: HIDInteractor.Session?, logger: SimUseLogger) async throws {
        try await performHIDEvent(.shortKeyPress(PasteHIDKeycode.applicationMenu), session: session, logger: logger)
    }

    private func pasteViaEditMenu(
        baseline: [PasteEditMenu.Item],
        emptyTargetConfirmed: Bool,
        calibration: OrientationCalibration?,
        session: HIDInteractor.Session?,
        verify: () async throws -> Void,
        logger: SimUseLogger
    ) async throws {
        let initial: [AccessibilityElement]
        do {
            initial = try await waitForEditMenu(excluding: baseline, logger: logger)
        } catch is MenuTimeout {
            let current = try await fetchLightweightTree(logger: logger)
            guard PasteEditMenu.item(labels: PasteEditMenu.pasteLabels, in: current, excluding: baseline) == nil else {
                throw MenuTimeout()
            }
            // Long-press can only move the caret, or Application can arrive
            // during the prior menu's dismissal. Retry invocation once, never
            // the Paste action and never against a visible, unsettled menu.
            try await openFocusedEditMenu(session: session, logger: logger)
            initial = try await waitForEditMenu(excluding: baseline, logger: logger)
        }
        var roots = initial
        let selectAll = PasteEditMenu.item(labels: PasteEditMenu.selectAllLabels, in: roots, excluding: baseline)
        if replace {
            try PasteEditMenu.validateReplacement(selectAll: selectAll, emptyTargetConfirmed: emptyTargetConfirmed)
        }
        if replace, let selectAll {
            try await tapMenuItem(selectAll, roots: roots, calibration: calibration, session: session, logger: logger)
            do {
                roots = try await waitForEditMenu(excluding: baseline, selectAllMustDisappear: true, logger: logger)
            } catch is MenuTimeout {
                // Long-pressing again would move the caret and undo Select All.
                try await openFocusedEditMenu(session: session, logger: logger)
                roots = try await waitForEditMenu(excluding: baseline, selectAllMustDisappear: true, logger: logger)
            }
        }
        guard let paste = PasteEditMenu.item(labels: PasteEditMenu.pasteLabels, in: roots, excluding: baseline) else {
            throw MenuTimeout()
        }
        try await verify()
        let latest = try await fetchLightweightTree(logger: logger)
        guard PasteEditMenu.item(labels: PasteEditMenu.pasteLabels, in: latest, excluding: baseline) == paste else {
            throw CLIError(errorDescription: "The edit menu changed before Paste. No paste action was sent.")
        }
        try await PasteDelivery.perform(
            send: { try await tapMenuItem(paste, roots: latest, calibration: calibration, session: session, logger: logger) },
            waitForCompletion: { try await waitForMenuDismissal(paste, logger: logger) }
        )
    }

    private func waitForMenuDismissal(_ clicked: PasteEditMenu.Item, logger: SimUseLogger) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(menuTimeout))
        var absentSince: ContinuousClock.Instant?
        while clock.now < deadline {
            let roots = try await fetchLightweightTree(logger: logger)
            if PasteEditMenu.isPresented(in: roots) || PasteEditMenu.items(in: roots).contains(clicked) {
                absentSince = nil
            } else {
                if let absentSince, absentSince.duration(to: clock.now) >= .milliseconds(300) { return }
                if absentSince == nil { absentSince = clock.now }
            }
            try await Task.sleep(for: .milliseconds(120))
        }
        throw CLIError(errorDescription: "Paste was sent, but the edit menu did not close. Verify the field before retrying; do not paste again without checking.")
    }

    private struct MenuTimeout: LocalizedError {
        var errorDescription: String? {
            "The iOS edit menu did not become ready. Focus an editable field first, or use --via-menu with --target-id or --target-x/--target-y. The control must support Paste and, for --replace, Select All."
        }
    }

    private func press(at point: (x: Double, y: Double), duration: Double, session: HIDInteractor.Session?, logger: SimUseLogger) async throws {
        let durationNs = UInt64(duration * 1_000_000_000)
        let down = FBSimulatorHIDEvent.touch(direction: .down, x: point.x, y: point.y)
        let up = FBSimulatorHIDEvent.touch(direction: .up, x: point.x, y: point.y)
        try await performHIDEvent(down, session: session, logger: logger)
        do {
            try await Task.sleep(nanoseconds: durationNs)
        } catch {
            try? await performHIDEvent(up, session: session, logger: logger)
            throw error
        }
        try await performHIDEvent(up, session: session, logger: logger)
    }

    private func waitForEditMenu(
        excluding baseline: [PasteEditMenu.Item], selectAllMustDisappear: Bool = false,
        logger: SimUseLogger
    ) async throws -> [AccessibilityElement] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(menuTimeout))
        var readiness = PasteEditMenu.Readiness()
        while clock.now < deadline {
            let roots = try await fetchLightweightTree(logger: logger)
            let labels = PasteEditMenu.pasteLabels.union(PasteEditMenu.selectAllLabels)
            let items = PasteEditMenu.actionItems(in: roots, excluding: baseline).filter { labels.contains($0.label) }
            if readiness.observe(items, at: clock.now, selectAllMustDisappear: selectAllMustDisappear) { return roots }
            try await Task.sleep(for: .milliseconds(120))
        }
        throw MenuTimeout()
    }

    private func tapMenuItem(
        _ item: PasteEditMenu.Item, roots: [AccessibilityElement],
        calibration: OrientationCalibration?, session: HIDInteractor.Session?, logger: SimUseLogger
    ) async throws {
        let effective: OrientationCalibration
        if let calibration { effective = calibration }
        else { effective = await OrientationCalibrator.calibrate(udid: device.resolved, roots: roots, logger: logger) }
        let hid = effective.hidPoint(x: item.frame.midX, y: item.frame.midY)
        logger.info().log("Tapping edit-menu \(item.label) at UI (\(item.frame.midX),\(item.frame.midY)), HID (\(hid.x),\(hid.y)), orientation \(effective.orientation.rawValue)")
        // Flush down before waiting, just like `tap --duration`. A composite
        // delay still delivers both transitions together on DTUHID, which
        // can dismiss the context menu without activating its item.
        try await press(at: hid, duration: 0.05, session: session, logger: logger)
    }

    private func performHIDEvent(_ event: FBSimulatorHIDEvent, session: HIDInteractor.Session?, logger: SimUseLogger) async throws {
        if let session {
            try await HIDInteractor.performHIDEvent(event, in: session, logger: logger)
        } else {
            try await HIDInteractor.performHIDEvent(event, for: device.resolved, logger: logger)
        }
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
            return try StandardInputText.read()
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

}

/// Standard USB keyboard usages used by paste delivery.
public enum PasteHIDKeycode {
    public static let applicationMenu: UInt32 = 101
    public static let escape: UInt32 = 41
    public static let rightArrow: UInt32 = 79
    public static let a: UInt32 = 4
    public static let v: UInt32 = 25
    public static let leftGUI: UInt32 = 227
}