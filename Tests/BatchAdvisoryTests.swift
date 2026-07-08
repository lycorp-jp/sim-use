// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

// The full-screen tap advisory must survive the batch path: selector
// steps resolve inside `toBatchPrimitives` (never the standalone tap
// command), so the advisory rides `BatchContext` into the batch
// `ExecutionResult` instead of the per-command envelope hoist. These
// tests pin that plumbing with an injected fetcher (no simulator).

/// One Application root: a wrapper covering the whole 400x800 screen
/// plus a small normal button.
private func makeAdvisoryTree() throws -> [AccessibilityElement] {
    let json = """
    [{"type": "Application", "AXLabel": "App", "frame": {"x": 0, "y": 0, "width": 400, "height": 800}, "children": [
        {"type": "Other", "AXLabel": "Flutter wrapper", "frame": {"x": 0, "y": 0, "width": 400, "height": 800}},
        {"type": "Button", "AXLabel": "Small", "frame": {"x": 10, "y": 700, "width": 100, "height": 40}, "enabled": true}
    ]}]
    """
    return try JSONDecoder().decode([AccessibilityElement].self, from: Data(json.utf8))
}

@MainActor
private func makeContext(tree: [AccessibilityElement]) -> BatchContext {
    BatchContext(
        simulatorUDID: "FAKE-UDID",
        axCachePolicy: .perBatch,
        typeSubmissionMode: .chunked,
        typeChunkSize: 200,
        fetchElements: { _, _ in tree },
        // The default calibrator needs a live simulator; a fixture tree
        // is upright by construction.
        calibrator: { _, _, _ in .identity() }
    )
}

private let quietLogger = SimUseLogger(writeToStdErr: false)

@Suite("Batch — full-screen tap advisory")
@MainActor
struct BatchAdvisoryTests {
    private func parseStep(_ tokens: [String], context: BatchContext) async throws -> [BatchPrimitive] {
        context.beginStep()
        return try await BatchStepParser.parseStepTokens(
            tokens,
            globalUDID: "FAKE-UDID",
            context: context,
            logger: quietLogger
        )
    }

    @Test("tap-by-label on a full-screen wrapper records a step-prefixed advisory")
    func recordsAdvisoryForFullScreenTap() async throws {
        let context = makeContext(tree: try makeAdvisoryTree())

        _ = try await parseStep(["tap", "--label", "Small"], context: context)
        _ = try await parseStep(["tap", "--label", "Flutter wrapper"], context: context)

        #expect(context.commandAdvisories.count == 1)
        let advisory = try #require(context.commandAdvisories.first)
        #expect(advisory.kind == .fullScreenTapTarget)
        #expect(advisory.message.hasPrefix("Step 2: "))
        #expect(advisory.message.contains("Flutter wrapper"))
    }

    @Test("coordinate and normal-selector steps record nothing")
    func noAdvisoryForNormalSteps() async throws {
        let context = makeContext(tree: try makeAdvisoryTree())

        _ = try await parseStep(["tap", "-x", "10", "-y", "10"], context: context)
        _ = try await parseStep(["tap", "--label", "Small"], context: context)

        #expect(context.commandAdvisories.isEmpty)
    }
}

// One calibration per batch run: selector steps share it, explicit
// coordinate steps never trigger it, and a degraded calibration warns
// exactly once (not once per step).
@Suite("Batch — orientation calibration")
@MainActor
struct BatchOrientationCalibrationTests {
    @MainActor
    private final class CalibratorSpy {
        var calls = 0
    }

    private func makeContext(tree: [AccessibilityElement], spy: CalibratorSpy) -> BatchContext {
        BatchContext(
            simulatorUDID: "FAKE-UDID",
            axCachePolicy: .perBatch,
            typeSubmissionMode: .chunked,
            typeChunkSize: 200,
            fetchElements: { _, _ in tree },
            calibrator: { _, _, _ in
                spy.calls += 1
                return OrientationCalibration(
                    orientation: .portraitUpsideDown,
                    native: NativePortraitSize(width: 400, height: 800),
                    probesUsed: 1,
                    advisory: CommandAdvisory(
                        kind: .orientationCalibrationFallback,
                        message: "orientation ambiguous"
                    )
                )
            }
        )
    }

    private func parseStep(_ tokens: [String], context: BatchContext) async throws -> [BatchPrimitive] {
        context.beginStep()
        return try await BatchStepParser.parseStepTokens(
            tokens,
            globalUDID: "FAKE-UDID",
            context: context,
            logger: quietLogger
        )
    }

    @Test("selector steps calibrate once per batch; explicit steps never")
    func calibratesOncePerBatch() async throws {
        let spy = CalibratorSpy()
        let context = makeContext(tree: try makeAdvisoryTree(), spy: spy)

        _ = try await parseStep(["tap", "-x", "10", "-y", "10"], context: context)
        #expect(spy.calls == 0)

        _ = try await parseStep(["tap", "--label", "Small"], context: context)
        _ = try await parseStep(["tap", "--label", "Small"], context: context)
        #expect(spy.calls == 1)

        // The degraded calibration warned exactly once, at first compute
        // (step 2), despite two selector steps reusing it.
        let orientationAdvisories = context.commandAdvisories.filter {
            $0.kind == .orientationCalibrationFallback
        }
        #expect(orientationAdvisories.count == 1)
        #expect(orientationAdvisories.first?.message.hasPrefix("Step 2: ") == true)
    }
}
