// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import FBSimulatorControl
import Foundation
import SimUseCore
import Testing

// Batch gesture steps have their own primitive-construction path
// (issue #66): directional presets must ride the batch-wide
// calibration exactly like tap selector steps — computed once per
// run, shared across steps, degrading to an identity dispatch with a
// recorded advisory instead of failing the batch. Pinch / rotate steps
// send the same two-finger trajectory as the standalone verb, in UI space
// by default (docs/ai/010-display-routing, S3).
// Endpoint math itself is pinned by GestureOrientationMappingTests.

private func makeSmallTree() throws -> [AccessibilityElement] {
    let json = """
    [{"type": "Application", "AXLabel": "App", "frame": {"x": 0, "y": 0, "width": 1376, "height": 1032}, "children": [
        {"type": "Button", "AXLabel": "Corner", "frame": {"x": 10, "y": 900, "width": 100, "height": 40}, "enabled": true}
    ]}]
    """
    return try JSONDecoder().decode([AccessibilityElement].self, from: Data(json.utf8))
}

private let quietLogger = SimUseLogger(writeToStdErr: false)

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

@Suite("Batch — gesture orientation")
@MainActor
struct BatchGestureOrientationTests {
    private func parseStep(_ tokens: [String], context: BatchContext) async throws -> [BatchPrimitive] {
        context.beginStep()
        return try await BatchStepParser.parseStepTokens(
            tokens,
            globalUDID: "FAKE-UDID",
            context: context,
            logger: quietLogger
        )
    }

    @Test("Directional gesture steps share one batch-wide calibration")
    func directionalStepsShareCalibration() async throws {
        let spy = CalibratorSpy(result: OrientationCalibration(
            orientation: .landscapeRight,
            native: NativePortraitSize(width: 1032, height: 1376),
            probesUsed: 1,
            advisory: nil
        ))
        let tree = try makeSmallTree()
        let context = BatchContext(
            simulatorUDID: "FAKE-UDID",
            axCachePolicy: .perBatch,
            typeSubmissionMode: .chunked,
            typeChunkSize: 200,
            fetchElements: { _, _ in tree },
            calibrator: { _, _, _ in spy.record() }
        )

        let first = try await parseStep(["gesture", "scroll-up"], context: context)
        let second = try await parseStep(["gesture", "scroll-left"], context: context)

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(spy.calls == 1)
        #expect(context.commandAdvisories.isEmpty)
    }

    private static let landscape = OrientationCalibration(
        orientation: .landscapeRight,
        native: NativePortraitSize(width: 1032, height: 1376),
        probesUsed: 1,
        advisory: nil
    )

    private func gestureCommand(_ arguments: [String]) throws -> IOSSimGestureCommand {
        try #require(try IOSSimGestureCommand.parseAsRoot(arguments + ["--udid", "FAKE-UDID"]) as? IOSSimGestureCommand)
    }

    private func twoFingerDown(_ primitives: [BatchPrimitive]) -> (CGPoint, CGPoint)? {
        guard primitives.count == 1, case .hidBarrier(let event) = primitives[0] else { return nil }
        func first(_ event: FBSimulatorHIDEvent) -> (CGPoint, CGPoint)? {
            switch event {
            case .twoFingerTouch(.down, let finger1, let finger2): return (finger1, finger2)
            case .composite(let events): return events.lazy.compactMap(first).first
            default: return nil
            }
        }
        return first(event)
    }

    @Test("Pinch steps send two fingers through the batch-wide calibration, like the standalone verb")
    func pinchUsesCalibration() async throws {
        let spy = CalibratorSpy(result: Self.landscape)
        let tree = try makeSmallTree()
        let context = BatchContext(
            simulatorUDID: "FAKE-UDID", axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200,
            fetchElements: { _, _ in tree }, calibrator: { _, _, _ in spy.record() }
        )
        let arguments = ["pinch-out", "--center-x", "300", "--center-y", "200", "--radius", "40"]
        let primitives = try await parseStep(["gesture"] + arguments, context: context)

        #expect(spy.calls == 1)
        let fingers = try #require(twoFingerDown(primitives), "expected one two-finger barrier")
        let standalone = try gestureCommand(arguments).multiTouchEvent(calibration: Self.landscape)
        #expect(primitives.count == 1)
        if case .hidBarrier(let event) = primitives[0] { #expect(event == standalone) }
        // The UI-space pivot (300, 200) crosses into HID space.
        let pivot = Self.landscape.hidPoint(x: 300, y: 200)
        #expect(abs((fingers.0.x + fingers.1.x) / 2 - pivot.x) < 0.5)
        #expect(abs((fingers.0.y + fingers.1.y) / 2 - pivot.y) < 0.5)
    }

    @Test("Native pinch steps keep raw coordinates and skip calibration")
    func nativePinchSkipsCalibration() async throws {
        let spy = CalibratorSpy(result: Self.landscape)
        let context = BatchContext(
            simulatorUDID: "FAKE-UDID", axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200,
            fetchElements: { _, _ in
                Issue.record("a native pinch should not fetch the AX tree")
                return []
            },
            calibrator: { _, _, _ in spy.record() }
        )
        let arguments = ["rotate-cw", "--center-x", "100", "--center-y", "500", "--coordinate-space", "native"]
        let primitives = try await parseStep(["gesture"] + arguments, context: context)

        #expect(spy.calls == 0)
        if case .hidBarrier(let event) = try #require(primitives.first) {
            #expect(event == (try gestureCommand(arguments).multiTouchEvent(calibration: nil)))
        } else {
            Issue.record("expected a two-finger barrier")
        }
    }

    @Test("An unreachable AX tree degrades to identity with a recorded advisory")
    func fetchFailureDegradesWithAdvisory() async throws {
        let context = BatchContext(
            simulatorUDID: "FAKE-UDID",
            axCachePolicy: .perBatch,
            typeSubmissionMode: .chunked,
            typeChunkSize: 200,
            fetchElements: { _, _ in throw CLIError(errorDescription: "no simulator") },
            calibrator: { _, _, _ in
                Issue.record("calibrator should not run when the tree fetch fails")
                return .identity()
            }
        )

        let primitives = try await parseStep(["gesture", "scroll-up"], context: context)

        #expect(primitives.count == 1)
        #expect(context.commandAdvisories.count == 1)
        let advisory = try #require(context.commandAdvisories.first)
        #expect(advisory.kind == .orientationCalibrationFallback)
        #expect(advisory.message.hasPrefix("Step 1: "))
        #expect(advisory.message.contains("scroll-up"))
    }
}
