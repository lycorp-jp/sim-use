// SPDX-License-Identifier: Apache-2.0
@testable import AndroidBackend
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

// PR B of issue #66: explicit swipe/touch coordinates keep their
// device-native portrait default (the issue #34 acceptance contract),
// and `--coordinate-space ui` opts endpoints into the visual space
// printed by describe-ui. These tests pin the opt-in rules:
//   * native stays zero-cost — no tree fetch, no calibration;
//   * ui rides the batch-wide calibration exactly like gesture presets;
//   * ui + split touch is rejected — the two halves could straddle a
//     rotation and land in different spaces.

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

    @Test("ui space with the atomic form validates")
    func atomicUIValidates() throws {
        try IOSSimTouchCommand.validateOptions(
            pointX: 10, pointY: 10, touchDown: true, touchUp: true,
            delay: nil, coordinateSpace: .ui)
    }

    @Test("ui space with a split --down rejects")
    func splitDownUIRejects() {
        #expect(throws: (any Error).self) {
            try IOSSimTouchCommand.validateOptions(
                pointX: 10, pointY: 10, touchDown: true, touchUp: false,
                delay: nil, coordinateSpace: .ui)
        }
    }

    @Test("ui space with a split --up rejects")
    func splitUpUIRejects() {
        #expect(throws: (any Error).self) {
            try IOSSimTouchCommand.validateOptions(
                pointX: 10, pointY: 10, touchDown: false, touchUp: true,
                delay: nil, coordinateSpace: .ui)
        }
    }

    @Test("native space keeps the split form working")
    func splitNativeStillValidates() throws {
        try IOSSimTouchCommand.validateOptions(
            pointX: 10, pointY: 10, touchDown: true, touchUp: false,
            delay: nil, coordinateSpace: .native)
    }
}

// Issue #142: `tap` gains the same opt-in for explicit -x/-y/--point.
// Aliases and selectors are already resolved in ui space, so combining
// them with `--coordinate-space ui` is a contradiction and rejects.

@Suite("Tap — coordinate-space validation")
struct TapCoordinateSpaceValidationTests {
    private static let udid = ["--udid", "FAKE-UDID"]

    @Test("ui space with explicit -x/-y validates")
    func explicitXYUIValidates() throws {
        _ = try IOSSimTapCommand.parseAsRoot(
            ["-x", "10", "-y", "10", "--coordinate-space", "ui"] + Self.udid)
    }

    @Test("ui space with --point validates")
    func explicitPointUIValidates() throws {
        _ = try IOSSimTapCommand.parseAsRoot(
            ["--point", "10,10", "--coordinate-space", "ui"] + Self.udid)
    }

    @Test("ui space with a selector rejects")
    func selectorUIRejects() {
        #expect(throws: (any Error).self) {
            _ = try IOSSimTapCommand.parseAsRoot(
                ["--label", "Foo", "--coordinate-space", "ui"] + Self.udid)
        }
    }

    @Test("ui space with an alias rejects")
    func aliasUIRejects() {
        #expect(throws: (any Error).self) {
            _ = try IOSSimTapCommand.parseAsRoot(
                ["@1", "--coordinate-space", "ui"] + Self.udid)
        }
    }

    @Test("native space (the default) keeps selectors working")
    func selectorNativeValidates() throws {
        _ = try IOSSimTapCommand.parseAsRoot(
            ["--label", "Foo", "--coordinate-space", "native"] + Self.udid)
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

    @Test("Native swipe steps stay zero-cost — no calibration")
    func nativeSwipeSkipsCalibration() async throws {
        let spy = CalibratorSpy(result: landscape)
        let context = makeContext(spy: spy, tree: try makeSmallTree())

        let primitives = try await parseStep(
            ["swipe", "--from", "100,200", "--to", "300,400"], context: context)

        #expect(primitives.count == 1)
        #expect(spy.calls == 0)
    }

    @Test("ui swipe steps ride the batch-wide calibration")
    func uiSwipeCalibrates() async throws {
        let spy = CalibratorSpy(result: landscape)
        let context = makeContext(spy: spy, tree: try makeSmallTree())

        let primitives = try await parseStep(
            ["swipe", "--from", "100,200", "--to", "300,400", "--coordinate-space", "ui"],
            context: context)

        #expect(primitives.count == 1)
        #expect(spy.calls == 1)
    }

    @Test("ui touch steps ride the batch-wide calibration")
    func uiTouchCalibrates() async throws {
        let spy = CalibratorSpy(result: landscape)
        let context = makeContext(spy: spy, tree: try makeSmallTree())

        let primitives = try await parseStep(
            ["touch", "-x", "100", "-y", "200", "--down", "--up", "--coordinate-space", "ui"],
            context: context)

        #expect(primitives.count == 3)
        #expect(spy.calls == 1)
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
            ["swipe", "--from", "100,200", "--to", "300,400", "--coordinate-space", "ui"],
            context: context)

        #expect(primitives.count == 1)
        #expect(spy.calls == 0)
        #expect(context.commandAdvisories.count == 1)
        #expect(context.commandAdvisories.first?.kind == .orientationCalibrationFallback)
    }

    @Test("Native tap -x/-y steps stay zero-cost — no calibration")
    func nativeTapSkipsCalibration() async throws {
        let spy = CalibratorSpy(result: landscape)
        let context = makeContext(spy: spy, tree: try makeSmallTree())

        let primitives = try await parseStep(
            ["tap", "-x", "100", "-y", "200"], context: context)

        #expect(primitives.count == 1)
        #expect(spy.calls == 0)
    }

    @Test("ui tap -x/-y steps ride the batch-wide calibration")
    func uiTapCalibrates() async throws {
        let spy = CalibratorSpy(result: landscape)
        let context = makeContext(spy: spy, tree: try makeSmallTree())

        let primitives = try await parseStep(
            ["tap", "-x", "100", "-y", "200", "--coordinate-space", "ui"], context: context)

        #expect(primitives.count == 1)
        #expect(spy.calls == 1)
    }

    @Test("ui tap with a selector is rejected at parse time")
    func selectorTapUIRejectsInBatch() async throws {
        let spy = CalibratorSpy(result: landscape)
        let context = makeContext(spy: spy, tree: try makeSmallTree())

        await #expect(throws: (any Error).self) {
            _ = try await parseStep(
                ["tap", "--label", "Corner", "--coordinate-space", "ui"], context: context)
        }
    }

    @Test("Split touch steps in ui space are rejected at parse time")
    func splitTouchUIRejectsInBatch() async throws {
        let spy = CalibratorSpy(result: landscape)
        let context = makeContext(spy: spy, tree: try makeSmallTree())

        await #expect(throws: (any Error).self) {
            _ = try await parseStep(
                ["touch", "-x", "100", "-y", "200", "--down", "--coordinate-space", "ui"],
                context: context)
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

    @Test("android touch parses --coordinate-space", arguments: ["native", "ui"])
    func androidTouchParsesFlag(value: String) throws {
        let parsed = try AndroidTouchCommand.parseAsRoot(
            ["-x", "1", "-y", "1", "--down", "--up", "--coordinate-space", value]
        ) as? AndroidTouchCommand
        let command = try #require(parsed)
        #expect(command.coordinateSpace.rawValue == value)
    }
}
