// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

public enum AXCachePolicy: String, CaseIterable, ExpressibleByArgument, Sendable {
    case perBatch
    case perStep
    case none
}

public enum TypeSubmissionMode: String, CaseIterable, ExpressibleByArgument, Sendable {
    case chunked
    case composite
}

@MainActor
public final class BatchContext {
    /// Fetches the AX tree for a UDID. Injectable so the cache policy
    /// semantics can be unit-tested without a booted simulator.
    public typealias ElementFetcher = @MainActor (String, SimUseLogger) async throws -> [AccessibilityElement]

    public let simulatorUDID: String
    public let axCachePolicy: AXCachePolicy
    public let typeSubmissionMode: TypeSubmissionMode
    public let typeChunkSize: Int
    public let waitTimeout: TimeInterval
    public let pollInterval: TimeInterval

    /// Computes the orientation calibration for a fetched tree.
    /// Injectable so batch calibration semantics (once per run) can be
    /// unit-tested without a booted simulator.
    public typealias Calibrator = @MainActor (String, [AccessibilityElement], SimUseLogger) async -> OrientationCalibration

    private let fetchElements: ElementFetcher
    private let calibrator: Calibrator
    private var cachedRoots: [AccessibilityElement]?
    /// One calibration per batch run: a batch is a single command
    /// execution, and per-command is the calibration cache boundary.
    private var cachedCalibration: OrientationCalibration?
    /// 1-based step number, advanced by `beginStep()`. Used to prefix
    /// recorded advisories so a multi-step run says which step warned
    /// (matching the "Step N failed" convention of the error path).
    private var currentStepNumber = 0
    /// Command advisories recorded while converting steps (e.g. a tap
    /// selector resolving to a near-full-screen element). Collected here
    /// because `BatchPrimitive`s carry only HID work — the batch command
    /// merges these into its `ExecutionResult` after the run.
    public private(set) var commandAdvisories: [CommandAdvisory] = []

    public init(
        simulatorUDID: String,
        axCachePolicy: AXCachePolicy,
        typeSubmissionMode: TypeSubmissionMode,
        typeChunkSize: Int,
        waitTimeout: TimeInterval = 0,
        pollInterval: TimeInterval = 0.25,
        fetchElements: @escaping ElementFetcher = { udid, logger in
            try await AccessibilityFetcher.fetchAccessibilityElements(for: udid, logger: logger)
        },
        calibrator: @escaping Calibrator = { udid, roots, logger in
            await OrientationCalibrator.calibrate(udid: udid, roots: roots, logger: logger)
        }
    ) {
        self.simulatorUDID = simulatorUDID
        self.axCachePolicy = axCachePolicy
        self.typeSubmissionMode = typeSubmissionMode
        self.typeChunkSize = typeChunkSize
        self.waitTimeout = waitTimeout
        self.pollInterval = pollInterval
        self.fetchElements = fetchElements
        self.calibrator = calibrator
    }

    /// Marks a step boundary. `.perStep` drops its snapshot here so the
    /// next selector resolution refetches; `.perBatch` keeps the snapshot
    /// for the whole run and `.none` never caches in the first place.
    public func beginStep() {
        currentStepNumber += 1
        if axCachePolicy == .perStep {
            cachedRoots = nil
        }
    }

    /// Record a per-command advisory raised while converting the current
    /// step, prefixed with the step number when the run has entered one.
    public func recordAdvisory(_ advisory: CommandAdvisory) {
        let message = currentStepNumber > 0
            ? "Step \(currentStepNumber): \(advisory.message)"
            : advisory.message
        commandAdvisories.append(CommandAdvisory(kind: advisory.kind, message: message))
    }

    /// Returns the AX roots honouring the cache policy. `forceRefresh`
    /// bypasses the cache and, for caching policies, replaces it — so a
    /// `--wait-timeout` poll tick propagates the fresh snapshot to later
    /// resolutions instead of resurrecting the stale one.
    public func accessibilityRoots(logger: SimUseLogger, forceRefresh: Bool = false) async throws -> [AccessibilityElement] {
        switch axCachePolicy {
        case .none:
            return try await fetchElements(simulatorUDID, logger)
        case .perStep, .perBatch:
            if !forceRefresh, let cachedRoots {
                return cachedRoots
            }
            let roots = try await fetchElements(simulatorUDID, logger)
            cachedRoots = roots
            return roots
        }
    }

    /// Returns the batch-wide orientation calibration, computing it
    /// lazily on the first AX-resolved step. A calibration advisory is
    /// recorded once at compute time — the run warns a single time, not
    /// on every step that reuses the cached result.
    public func orientationCalibration(roots: [AccessibilityElement], logger: SimUseLogger) async -> OrientationCalibration {
        if let cachedCalibration {
            return cachedCalibration
        }
        let calibration = await calibrator(simulatorUDID, roots, logger)
        cachedCalibration = calibration
        if let advisory = calibration.advisory {
            recordAdvisory(advisory)
        }
        return calibration
    }
}