// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBSimulatorControl
import SimUseCore

/// Conformance attached to the iOS-side verb command structs so the
/// `batch` step parser can lift a parsed step into a sequence of
/// `BatchPrimitive`s. iOS-only HID verbs (`key`, `key-combo`,
/// `key-sequence`, `stream-video`, `batch`) have no top-level
/// cross-platform wrapper, and the cross-platform verbs (Tap / Type /
/// Paste / Button / Swipe / Touch / Gesture) keep all their
/// batch-relevant state on their `IOSSim<Verb>Command` sub-struct —
/// so attaching here is the single canonical home for both.
@MainActor
public protocol BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: SimUseLogger) async throws -> [BatchPrimitive]
}

private func buildDelayedEvent(
    preDelay: Double?,
    mainEvent: FBSimulatorHIDEvent,
    postDelay: Double?
) -> FBSimulatorHIDEvent {
    var events: [FBSimulatorHIDEvent] = []
    if let preDelay, preDelay > 0 {
        events.append(.delay(preDelay))
    }
    events.append(mainEvent)
    if let postDelay, postDelay > 0 {
        events.append(.delay(postDelay))
    }
    return events.count == 1 ? events[0] : FBSimulatorHIDEvent(events: events)
}

extension IOSSimTapCommand: BatchConvertible {
    public func toBatchPrimitives(context: BatchContext, logger: SimUseLogger) async throws -> [BatchPrimitive] {
        // Dispatch coordinates: framebuffer space for AX-resolved
        // selectors (issue #34), raw for explicit --point/-x/-y.
        let resolvedPoint: (x: Double, y: Double)

        if let explicit = try TapCoordinateResolver.resolve(x: pointX, y: pointY, point: point) {
            resolvedPoint = (explicit.x, explicit.y)
        } else {
            let query: AccessibilityQuery
            if let elementID {
                query = .id(elementID)
            } else if let elementLabel {
                query = .label(elementLabel)
            } else if let elementValue {
                query = .value(elementValue)
            } else if let labelContains {
                query = .labelContains(labelContains)
            } else if let labelRegex {
                query = .labelRegex(pattern: labelRegex)
            } else {
                throw CLIError(errorDescription: "Unexpected state: no coordinates and no element query.")
            }

            let hidTarget = try await AccessibilityPoller.resolveWithPollingHIDTarget(
                query: query,
                simulatorUDID: context.simulatorUDID,
                waitTimeout: context.waitTimeout,
                pollInterval: context.pollInterval,
                elementType: elementType,
                frameFilter: frameFilter,
                rootsProvider: { forceRefresh in
                    let roots = try await context.accessibilityRoots(logger: logger, forceRefresh: forceRefresh)
                    // Batch-wide lazy calibration; its advisory is
                    // recorded once inside the context.
                    let calibration = await context.orientationCalibration(roots: roots, logger: logger)
                    return (roots, calibration)
                },
                logger: logger
            )
            resolvedPoint = hidTarget.hid
            // Same full-screen-wrapper warning the standalone tap emits;
            // batch has no per-step envelope, so it rides the context to
            // the batch ExecutionResult.
            if let advisory = hidTarget.target.advisory {
                context.recordAdvisory(advisory)
            }
        }

        if let duration, duration > 0 {
            // Match the discrete-execute path: split into down → host
            // sleep → up so UIKit recognisers see a real hold. Pre/post
            // delays bracket the whole sequence as host sleeps.
            var primitives: [BatchPrimitive] = []
            if let preDelay, preDelay > 0 {
                primitives.append(.hostSleep(preDelay))
            }
            primitives.append(.hidBarrier(.touchDownAt(x: resolvedPoint.x, y: resolvedPoint.y)))
            primitives.append(.hostSleep(duration))
            primitives.append(.hidBarrier(.touchUpAt(x: resolvedPoint.x, y: resolvedPoint.y)))
            if let postDelay, postDelay > 0 {
                primitives.append(.hostSleep(postDelay))
            }
            return primitives
        }

        let tapEvent = FBSimulatorHIDEvent.tapAt(x: resolvedPoint.x, y: resolvedPoint.y)
        return [.hidMergeable(buildDelayedEvent(preDelay: preDelay, mainEvent: tapEvent, postDelay: postDelay))]
    }
}

extension IOSSimSwipeCommand: BatchConvertible {
    public func toBatchPrimitives(context: BatchContext, logger: SimUseLogger) async throws -> [BatchPrimitive] {
        let coords = try resolvedCoordinates()
        let swipeDuration = duration ?? 1.0
        let swipeDelta = delta ?? 50.0
        let swipeEvent = FBSimulatorHIDEvent.swipe(
            coords.startX,
            yStart: coords.startY,
            xEnd: coords.endX,
            yEnd: coords.endY,
            delta: swipeDelta,
            duration: swipeDuration
        )
        return [.hidMergeable(buildDelayedEvent(preDelay: preDelay, mainEvent: swipeEvent, postDelay: postDelay))]
    }
}

extension IOSSimGestureCommand: BatchConvertible {
    public func toBatchPrimitives(context: BatchContext, logger: SimUseLogger) async throws -> [BatchPrimitive] {
        let width = screenWidth ?? 390.0
        let height = screenHeight ?? 844.0
        let coords = preset.coordinates(screenWidth: width, screenHeight: height)
        let gestureDuration = duration ?? preset.defaultDuration
        let gestureDelta = delta ?? preset.defaultDelta

        let gestureEvent = FBSimulatorHIDEvent.swipe(
            coords.startX,
            yStart: coords.startY,
            xEnd: coords.endX,
            yEnd: coords.endY,
            delta: gestureDelta,
            duration: gestureDuration
        )

        return [.hidMergeable(buildDelayedEvent(preDelay: preDelay, mainEvent: gestureEvent, postDelay: postDelay))]
    }
}

extension IOSSimTouchCommand: BatchConvertible {
    public func toBatchPrimitives(context: BatchContext, logger: SimUseLogger) async throws -> [BatchPrimitive] {
        let touchDownEvent = FBSimulatorHIDEvent.touchDownAt(x: pointX, y: pointY)
        let touchUpEvent = FBSimulatorHIDEvent.touchUpAt(x: pointX, y: pointY)

        if touchDown && touchUp {
            let holdDelay = delay ?? 0.1
            return [
                .hidBarrier(touchDownEvent),
                .hostSleep(holdDelay),
                .hidBarrier(touchUpEvent)
            ]
        }

        if touchDown {
            return [.hidMergeable(touchDownEvent)]
        }

        return [.hidMergeable(touchUpEvent)]
    }
}

extension IOSSimButtonCommand: BatchConvertible {
    public func toBatchPrimitives(context: BatchContext, logger: SimUseLogger) async throws -> [BatchPrimitive] {
        // Batches run against a single iOS simulator session, so an
        // Android-only button (back / recents) inside a batch is a
        // user error. Surface it instead of falling through to a
        // nil-force-unwrap crash on `iosHidButton`.
        guard let hidButton = buttonType.iosHidButton else {
            throw CLIError(errorDescription:
                "`button \(buttonType.rawValue)` is not supported inside an iOS batch. Supported on iOS: \(ButtonType.supportedOnIOSList)."
            )
        }
        if let duration {
            let composite = FBSimulatorHIDEvent(events: [
                .buttonDown(hidButton),
                .delay(duration),
                .buttonUp(hidButton)
            ])
            return [.hidMergeable(composite)]
        }

        return [.hidMergeable(.shortButtonPress(hidButton))]
    }
}

extension IOSSimKeyCommand: BatchConvertible {
    public func toBatchPrimitives(context: BatchContext, logger: SimUseLogger) async throws -> [BatchPrimitive] {
        if let duration {
            let composite = FBSimulatorHIDEvent(events: [
                .keyDown(UInt32(keycode)),
                .delay(duration),
                .keyUp(UInt32(keycode))
            ])
            return [.hidMergeable(composite)]
        }

        return [.hidMergeable(.shortKeyPress(UInt32(keycode)))]
    }
}

extension IOSSimKeySequenceCommand: BatchConvertible {
    public func toBatchPrimitives(context: BatchContext, logger: SimUseLogger) async throws -> [BatchPrimitive] {
        let parsedKeycodes = try parseCommaSeparatedIntsStrict(keycodesString, fieldName: "keycodes")
        let keyDelay = delay ?? 0.1
        var events: [FBSimulatorHIDEvent] = []

        for (index, keycode) in parsedKeycodes.enumerated() {
            events.append(.shortKeyPress(UInt32(keycode)))
            if index < parsedKeycodes.count - 1 && keyDelay > 0 {
                events.append(.delay(keyDelay))
            }
        }

        return [.hidMergeable(FBSimulatorHIDEvent(events: events))]
    }
}

extension IOSSimKeyComboCommand: BatchConvertible {
    public func toBatchPrimitives(context: BatchContext, logger: SimUseLogger) async throws -> [BatchPrimitive] {
        let parsedModifiers = try parseCommaSeparatedIntsStrict(modifiersString, fieldName: "modifier keycodes")

        var events: [FBSimulatorHIDEvent] = []
        for modifier in parsedModifiers {
            events.append(.keyDown(UInt32(modifier)))
        }
        events.append(.shortKeyPress(UInt32(key)))
        for modifier in parsedModifiers.reversed() {
            events.append(.keyUp(UInt32(modifier)))
        }

        return [.hidMergeable(FBSimulatorHIDEvent(events: events))]
    }
}

extension IOSSimPasteCommand: BatchConvertible {
    public func toBatchPrimitives(context: BatchContext, logger: SimUseLogger) async throws -> [BatchPrimitive] {
        // `--via-menu` requires runtime AX-tree polling for the iOS edit
        // menu and a tap on a label-resolved target. That's well outside
        // the deterministic HID-stream model batch is built around;
        // surface it explicitly instead of half-implementing it.
        guard !viaMenu else {
            throw ValidationError("`paste --via-menu` is not supported as a batch step yet. Run `sim-use paste --via-menu` as a standalone command.")
        }
        // `--stdin` is meaningless inside a batch because each step is
        // already one parsed line; reject early so the daemon-side
        // bypass logic on `Batch` doesn't have to special-case it.
        guard !useStdin else {
            throw ValidationError("`paste --stdin` is not supported as a batch step. Pass the text inline (`paste 'hello'`) or via `--file`.")
        }

        let inputText: String
        if let text {
            inputText = text
        } else if let inputFile {
            do {
                inputText = try String(contentsOfFile: inputFile, encoding: .utf8)
            } catch {
                throw ValidationError("Failed to read paste input file '\(inputFile)': \(error.localizedDescription)")
            }
        } else {
            throw ValidationError("`paste` step requires inline text or `--file <path>`.")
        }

        guard !inputText.isEmpty else {
            throw ValidationError("`paste` step text is empty; nothing to paste.")
        }

        let udid = context.simulatorUDID
        let shouldReplace = replace

        let pbcopyAction = BatchHostAction(label: "simctl pbcopy (\(inputText.utf8.count) bytes)") { _, _ in
            try IOSSimPasteCommand.writeSimulatorPasteboard(text: inputText, udid: udid)
        }

        var primitives: [BatchPrimitive] = [.hostAction(pbcopyAction)]

        if shouldReplace {
            primitives.append(.hidBarrier(modifierCombo(
                key: PasteHIDKeycode.a,
                modifier: PasteHIDKeycode.leftGUI
            )))
        }

        primitives.append(.hidBarrier(modifierCombo(
            key: PasteHIDKeycode.v,
            modifier: PasteHIDKeycode.leftGUI
        )))

        return primitives
    }

    private func modifierCombo(key: UInt32, modifier: UInt32) -> FBSimulatorHIDEvent {
        FBSimulatorHIDEvent(events: [
            FBSimulatorHIDEvent.keyDown(modifier),
            FBSimulatorHIDEvent.shortKeyPress(key),
            FBSimulatorHIDEvent.keyUp(modifier),
        ])
    }
}

extension IOSSimTypeCommand: BatchConvertible {
    public func toBatchPrimitives(context: BatchContext, logger: SimUseLogger) async throws -> [BatchPrimitive] {
        let inputText: String
        switch (text, useStdin, inputFile) {
        case (let positionalText?, false, nil):
            inputText = positionalText
        case (nil, true, nil):
            inputText = IOSSimTypeCommand.readFromStdin()
        case (nil, false, let file?):
            inputText = try IOSSimTypeCommand.readFromFile(file)
        default:
            throw CLIError(errorDescription: "Invalid input configuration.")
        }

        guard TextToHIDEvents.validateText(inputText) else {
            let unsupportedChars = inputText.compactMap { char -> Character? in
                let keyEvent = KeyEvent.keyCodeForString(String(char))
                return keyEvent.keyCode == 0 ? char : nil
            }
            throw TextToHIDEvents.TextConversionError.unsupportedCharacter(unsupportedChars.first ?? " ")
        }

        let hidEvents = try TextToHIDEvents.convertTextToHIDEvents(inputText)
        guard !hidEvents.isEmpty else {
            return []
        }

        switch context.typeSubmissionMode {
        case .composite:
            return [.hidMergeable(FBSimulatorHIDEvent(events: hidEvents))]
        case .chunked:
            let chunkSize = max(1, context.typeChunkSize)
            var primitives: [BatchPrimitive] = []
            var start = 0
            while start < hidEvents.count {
                let end = min(start + chunkSize, hidEvents.count)
                let chunkEvents = Array(hidEvents[start..<end])
                primitives.append(.hidBarrier(FBSimulatorHIDEvent(events: chunkEvents)))
                start = end
            }
            return primitives
        }
    }
}
