// SPDX-License-Identifier: Apache-2.0
@testable import AndroidBackend
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

// Explicit iOS coordinates are UI space by default — the space every
// frame printed by describe-ui uses (docs/ai/010-display-routing, S3;
// before that the opt-in of issues #66 / #142). These tests pin:
//   * ui is the default and rides the batch-wide calibration exactly
//     like gesture presets;
//   * `--coordinate-space native` stays zero-cost — no tree fetch, no
//     calibration;
//   * the split touch form takes ui coordinates too; each half maps
//     through the orientation at its own time.

private let quietLogger = SimUseLogger(writeToStdErr: false)

private func makeSmallTree() throws -> [AccessibilityElement] {
    let json = """
    [{"type": "Application", "AXLabel": "App", "frame": {"x": 0, "y": 0, "width": 1376, "height": 1032}, "children": [
        {"type": "Button", "AXLabel": "Corner", "frame": {"x": 10, "y": 900, "width": 100, "height": 40}, "enabled": true}
    ]}]
    """
    return try JSONDecoder().decode([AccessibilityElement].self, from: Data(json.utf8))
}

@MainActor
private final class CalibratorSpy {
    private(set) var calls = 0
    let result: OrientationCalibration

    init(result: OrientationCalibration) {
        self.result = result
    }

    func record() -> OrientationCalibration {
        calls += 1
        return result
    }
}

@MainActor
private func makeContext(spy: CalibratorSpy, tree: [AccessibilityElement]) -> BatchContext {
    BatchContext(
        simulatorUDID: "FAKE-UDID",
        axCachePolicy: .perBatch,
        typeSubmissionMode: .chunked,
        typeChunkSize: 200,
        fetchElements: { _, _ in tree },
        calibrator: { _, _, _ in spy.record() }
    )
}

@Suite("Touch — coordinate-space validation")
struct TouchCoordinateSpaceValidationTests {

    @Test("ui is the default")
    func defaultIsUI() throws {
        let command = try #require(try IOSSimTouchCommand.parseAsRoot(
            ["-x", "10", "-y", "10", "--down", "--up", "--udid", "FAKE-UDID"]) as? IOSSimTouchCommand)
        #expect(command.coordinateSpace == .ui)
    }

    @Test("ui space with the atomic form validates")
    func atomicUIValidates() throws {
        try IOSSimTouchCommand.validateOptions(
            pointX: 10, pointY: 10, touchDown: true, touchUp: true,
            delay: nil, coordinateSpace: .ui)
    }

    @Test("ui space with a split --down or --up validates", arguments: [(true, false), (false, true)])
    func splitUIValidates(down: Bool, up: Bool) throws {
        try IOSSimTouchCommand.validateOptions(
            pointX: 10, pointY: 10, touchDown: down, touchUp: up,
            delay: nil, coordinateSpace: .ui)
    }

    @Test("native space keeps the split form working")
    func splitNativeStillValidates() throws {
        try IOSSimTouchCommand.validateOptions(
            pointX: 10, pointY: 10, touchDown: true, touchUp: false,
            delay: nil, coordinateSpace: .native)
    }
}

// Aliases and selectors are already resolved in ui space, so
// `--coordinate-space` (either value) is a contradiction there and
// rejects. Explicit -x/-y/--point default to ui.

@Suite("Tap — coordinate-space validation")
struct TapCoordinateSpaceValidationTests {
    private static let udid = ["--udid", "FAKE-UDID"]

    private func parse(_ arguments: [String]) throws -> IOSSimTapCommand {
        try #require(try IOSSimTapCommand.parseAsRoot(arguments + Self.udid) as? IOSSimTapCommand)
    }

    @Test("explicit -x/-y default to ui")
    func explicitXYDefaultsToUI() throws {
        let command = try parse(["-x", "10", "-y", "10"])
        #expect(command.targeting.coordinateSpace == nil)
        #expect(command.targeting.effectiveCoordinateSpace == .ui)
    }

    @Test("native opts explicit coordinates out", arguments: [["-x", "10", "-y", "10"], ["--point", "10,10"]])
    func explicitNativeValidates(coordinates: [String]) throws {
        let command = try parse(coordinates + ["--coordinate-space", "native"])
        #expect(command.targeting.effectiveCoordinateSpace == .native)
    }

    @Test("ui space with --point validates")
    func explicitPointUIValidates() throws {
        _ = try parse(["--point", "10,10", "--coordinate-space", "ui"])
    }

    @Test("either space with a selector rejects", arguments: ["ui", "native"])
    func selectorRejects(space: String) {
        #expect(throws: (any Error).self) {
            _ = try parse(["--label", "Foo", "--coordinate-space", space])
        }
    }

    @Test("either space with an alias rejects", arguments: ["ui", "native"])
    func aliasRejects(space: String) {
        #expect(throws: (any Error).self) {
            _ = try parse(["@1", "--coordinate-space", space])
        }
    }

    @Test("selectors without the flag validate")
    func selectorValidates() throws {
        _ = try parse(["--label", "Foo"])
    }
}

@Suite("Multi-touch and gesture — coordinate-space options")
struct MultiTouchGestureCoordinateSpaceTests {
    private static let fingers = [
        "--x1", "100", "--y1", "200", "--x2", "150", "--y2", "200",
        "--x1-end", "50", "--y1-end", "200", "--x2-end", "200", "--y2-end", "200",
        "--udid", "FAKE-UDID",
    ]

    @Test("multi-touch defaults to ui; native parses")
    func multiTouchDefault() throws {
        let byDefault = try #require(try IOSSimMultiTouchCommand.parseAsRoot(Self.fingers) as? IOSSimMultiTouchCommand)
        #expect(byDefault.coordinateSpace == .ui)
        let native = try #require(try IOSSimMultiTouchCommand.parseAsRoot(
            Self.fingers + ["--coordinate-space", "native"]) as? IOSSimMultiTouchCommand)
        #expect(native.coordinateSpace == .native)
    }

    @Test("pinch and rotate default to ui and accept native", arguments: ["pinch-out", "rotate-cw"])
    func multiTouchPresetSpace(preset: String) throws {
        let byDefault = try #require(try IOSSimGestureCommand.parseAsRoot(
            [preset, "--udid", "FAKE-UDID"]) as? IOSSimGestureCommand)
        #expect(byDefault.effectiveCoordinateSpace == .ui)
        let native = try #require(try IOSSimGestureCommand.parseAsRoot(
            [preset, "--coordinate-space", "native", "--udid", "FAKE-UDID"]) as? IOSSimGestureCommand)
        #expect(native.effectiveCoordinateSpace == .native)
    }

    @Test("a directional preset rejects the flag", arguments: ["ui", "native"])
    func directionalPresetRejects(space: String) {
        #expect(throws: (any Error).self) {
            _ = try IOSSimGestureCommand.parseAsRoot(
                ["scroll-up", "--coordinate-space", space, "--udid", "FAKE-UDID"])
        }
    }

    @Test("a UI-space trajectory maps every sample into HID space")
    func trajectoryMapsEverySample() {
        // landscape-right on a 402x874 portrait canvas: UI (x, y) →
        // HID (402 − y, x).
        let calibration = OrientationCalibration(
            orientation: .landscapeRight,
            native: NativePortraitSize(width: 402, height: 874),
            probesUsed: 1,
            advisory: nil
        )
        let mapped = MultiTouchDispatcher.hidTrajectory(calibration) { t in
            ((x: 100 + 100 * t, y: 50), (x: 300, y: 50 + 100 * t))
        }
        let start = mapped(0)
        let middle = mapped(0.5)
        #expect(start.0.x == 352 && start.0.y == 100)
        #expect(start.1.x == 352 && start.1.y == 300)
        #expect(middle.0.x == 352 && middle.0.y == 150)
        #expect(middle.1.x == 302 && middle.1.y == 300)
    }
}

@Suite("Batch — swipe/touch coordinate space")
@MainActor
struct BatchCoordinateSpaceTests {
    private func parseStep(_ tokens: [String], context: BatchContext) async throws -> [BatchPrimitive] {
        context.beginStep()
        return try await BatchStepParser.parseStepTokens(
            tokens,
            globalUDID: "FAKE-UDID",
            context: context,
            logger: quietLogger
        )
    }

    private var landscape: OrientationCalibration {
        OrientationCalibration(
            orientation: .landscapeRight,
            native: NativePortraitSize(width: 1032, height: 1376),
            probesUsed: 1,
            advisory: nil
        )
    }

    @Test("swipe steps calibrate by default; native stays zero-cost")
    func swipeSpaces() async throws {
        for (extra, calls) in [([String](), 1), (["--coordinate-space", "native"], 0)] {
            let spy = CalibratorSpy(result: landscape)
            let context = makeContext(spy: spy, tree: try makeSmallTree())
            let primitives = try await parseStep(
                ["swipe", "--from", "100,200", "--to", "300,400"] + extra, context: context)
            #expect(primitives.count == 1)
            #expect(spy.calls == calls)
        }
    }

    @Test("touch steps calibrate by default, atomic and split")
    func touchDefaultCalibrates() async throws {
        for (form, count) in [(["--down", "--up"], 3), (["--down"], 1), (["--up"], 1)] {
            let spy = CalibratorSpy(result: landscape)
            let context = makeContext(spy: spy, tree: try makeSmallTree())
            let primitives = try await parseStep(["touch", "-x", "100", "-y", "200"] + form, context: context)
            #expect(primitives.count == count)
            #expect(spy.calls == 1)
        }
    }

    @Test("native touch steps stay zero-cost")
    func nativeTouchSkipsCalibration() async throws {
        let spy = CalibratorSpy(result: landscape)
        let context = makeContext(spy: spy, tree: try makeSmallTree())
        _ = try await parseStep(
            ["touch", "-x", "100", "-y", "200", "--down", "--up", "--coordinate-space", "native"],
            context: context)
        #expect(spy.calls == 0)
    }

    @Test("ui swipe with an unreachable tree degrades with a recorded advisory")
    func uiSwipeFetchFailureDegrades() async throws {
        let spy = CalibratorSpy(result: landscape)
        let context = BatchContext(
            simulatorUDID: "FAKE-UDID",
            axCachePolicy: .perBatch,
            typeSubmissionMode: .chunked,
            typeChunkSize: 200,
            fetchElements: { _, _ in throw CLIError(errorDescription: "no simulator") },
            calibrator: { _, _, _ in spy.record() }
        )

        let primitives = try await parseStep(
            ["swipe", "--from", "100,200", "--to", "300,400"],
            context: context)

        #expect(primitives.count == 1)
        #expect(spy.calls == 0)
        #expect(context.commandAdvisories.count == 1)
        #expect(context.commandAdvisories.first?.kind == .orientationCalibrationFallback)
    }

    @Test("tap -x/-y steps calibrate by default; native stays zero-cost")
    func tapSpaces() async throws {
        for (extra, calls) in [([String](), 1), (["--coordinate-space", "native"], 0)] {
            let spy = CalibratorSpy(result: landscape)
            let context = makeContext(spy: spy, tree: try makeSmallTree())
            let primitives = try await parseStep(["tap", "-x", "100", "-y", "200"] + extra, context: context)
            #expect(primitives.count == 1)
            #expect(spy.calls == calls)
        }
    }

    @Test("default-space steps share one batch-wide calibration")
    func stepsShareCalibration() async throws {
        let spy = CalibratorSpy(result: landscape)
        let context = makeContext(spy: spy, tree: try makeSmallTree())
        _ = try await parseStep(["tap", "-x", "100", "-y", "200"], context: context)
        _ = try await parseStep(["swipe", "--from", "100,200", "--to", "300,400"], context: context)
        _ = try await parseStep(["touch", "-x", "100", "-y", "200", "--down", "--up"], context: context)
        #expect(spy.calls == 1)
    }

    @Test("a tap selector with the flag is rejected at parse time")
    func selectorTapFlagRejectsInBatch() async throws {
        let spy = CalibratorSpy(result: landscape)
        let context = makeContext(spy: spy, tree: try makeSmallTree())

        await #expect(throws: (any Error).self) {
            _ = try await parseStep(
                ["tap", "--label", "Corner", "--coordinate-space", "ui"], context: context)
        }
    }
}

// The top-level commands promise that --coordinate-space is accepted
// everywhere and ignored on Android, and every Android direct command
// mirrors its top-level/iOS flag surface — so `sim-use android
// swipe/touch` must parse the flag too (as a no-op).

@Suite("Android — coordinate-space parser parity")
struct AndroidCoordinateSpaceParityTests {

    @Test("android swipe parses --coordinate-space", arguments: ["native", "ui"])
    func androidSwipeParsesFlag(value: String) throws {
        let parsed = try AndroidSwipeCommand.parseAsRoot(
            ["--from", "1,1", "--to", "2,2", "--coordinate-space", value]
        ) as? AndroidSwipeCommand
        let command = try #require(parsed)
        #expect(command.coordinateSpace.rawValue == value)
        let coords = try command.coordinates.resolve()
        #expect(coords.startX == 1 && coords.endY == 2)
    }

    @Test("android tap parses --coordinate-space", arguments: ["native", "ui"])
    func androidTapParsesFlag(value: String) throws {
        let parsed = try AndroidTapCommand.parseAsRoot(
            ["-x", "1", "-y", "1", "--coordinate-space", value]
        ) as? AndroidTapCommand
        let command = try #require(parsed)
        #expect(command.coordinateSpace.rawValue == value)
    }

    @Test("android coordinate verbs default to ui")
    func androidDefaults() throws {
        let tap = try #require(try AndroidTapCommand.parseAsRoot(["-x", "1", "-y", "1"]) as? AndroidTapCommand)
        let swipe = try #require(try AndroidSwipeCommand.parseAsRoot(["--from", "1,1", "--to", "2,2"]) as? AndroidSwipeCommand)
        let touch = try #require(try AndroidTouchCommand.parseAsRoot(["-x", "1", "-y", "1", "--down", "--up"]) as? AndroidTouchCommand)
        #expect(tap.coordinateSpace == .ui && swipe.coordinateSpace == .ui && touch.coordinateSpace == .ui)
    }

    @Test("android multi-touch and gesture parse --coordinate-space", arguments: ["native", "ui"])
    func androidMultiTouchGestureParseFlag(value: String) throws {
        _ = try AndroidMultiTouchCommand.parseAsRoot(
            ["--x1", "1", "--y1", "1", "--x2", "2", "--y2", "2",
             "--x1-end", "1", "--y1-end", "1", "--x2-end", "2", "--y2-end", "2",
             "--coordinate-space", value])
        _ = try AndroidGestureCommand.parseAsRoot(["pinch-out", "--coordinate-space", value])
    }

    @Test("android touch parses --coordinate-space", arguments: ["native", "ui"])
    func androidTouchParsesFlag(value: String) throws {
        let parsed = try AndroidTouchCommand.parseAsRoot(
            ["-x", "1", "-y", "1", "--down", "--up", "--coordinate-space", value]
        ) as? AndroidTouchCommand
        let command = try #require(parsed)
        #expect(command.coordinateSpace.rawValue == value)
    }
}

// `paste --via-menu --target-x/-y` follows `tap -x/-y`: UI space by
// default, `--coordinate-space native` opts out, and the flag needs the
// coordinate target.

@Suite("Paste — coordinate-space validation")
struct PasteCoordinateSpaceValidationTests {
    private func validate(targetID: String? = nil, x: Double? = nil, y: Double? = nil, space: CoordinateSpace?) throws {
        try IOSSimPasteCommand.validateOptions(
            text: "a", useStdin: false, inputFile: nil, viaMenu: true,
            targetID: targetID, targetX: x, targetY: y, coordinateSpace: space)
    }

    @Test("--target-x/-y accept either space or none", arguments: [nil, CoordinateSpace.ui, .native])
    func coordinateTarget(space: CoordinateSpace?) throws {
        try validate(x: 10, y: 20, space: space)
    }

    @Test("--target-id rejects the flag")
    func idTargetRejects() {
        #expect(throws: (any Error).self) { try validate(targetID: "field", space: .native) }
    }

    @Test("the iOS paste command defaults to ui")
    func defaultIsUI() throws {
        let command = try #require(try IOSSimPasteCommand.parseAsRoot(
            ["a", "--via-menu", "--target-x", "10", "--target-y", "20", "--udid", "FAKE-UDID"]) as? IOSSimPasteCommand)
        #expect(command.effectiveCoordinateSpace == .ui)
    }
}
