// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation

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
    public let simulatorUDID: String
    public let axCachePolicy: AXCachePolicy
    public let typeSubmissionMode: TypeSubmissionMode
    public let typeChunkSize: Int
    public let waitTimeout: TimeInterval
    public let pollInterval: TimeInterval

    private var cachedRoots: [AccessibilityElement]?

    public init(
        simulatorUDID: String,
        axCachePolicy: AXCachePolicy,
        typeSubmissionMode: TypeSubmissionMode,
        typeChunkSize: Int,
        waitTimeout: TimeInterval = 0,
        pollInterval: TimeInterval = 0.25
    ) {
        self.simulatorUDID = simulatorUDID
        self.axCachePolicy = axCachePolicy
        self.typeSubmissionMode = typeSubmissionMode
        self.typeChunkSize = typeChunkSize
        self.waitTimeout = waitTimeout
        self.pollInterval = pollInterval
    }

    public func accessibilityRoots(logger: SimUseLogger, forceRefresh: Bool = false) async throws -> [AccessibilityElement] {
        switch axCachePolicy {
        case .none:
            return try await AccessibilityFetcher.fetchAccessibilityElements(for: simulatorUDID, logger: logger)
        case .perStep:
            return try await AccessibilityFetcher.fetchAccessibilityElements(for: simulatorUDID, logger: logger)
        case .perBatch:
            if !forceRefresh, let cachedRoots {
                return cachedRoots
            }
            let roots = try await AccessibilityFetcher.fetchAccessibilityElements(for: simulatorUDID, logger: logger)
            cachedRoots = roots
            return roots
        }
    }
}