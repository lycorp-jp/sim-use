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
    /// Fetches the AX tree for a UDID. Injectable so the cache policy
    /// semantics can be unit-tested without a booted simulator.
    public typealias ElementFetcher = @MainActor (String, SimUseLogger) async throws -> [AccessibilityElement]

    public let simulatorUDID: String
    public let axCachePolicy: AXCachePolicy
    public let typeSubmissionMode: TypeSubmissionMode
    public let typeChunkSize: Int
    public let waitTimeout: TimeInterval
    public let pollInterval: TimeInterval

    private let fetchElements: ElementFetcher
    private var cachedRoots: [AccessibilityElement]?

    public init(
        simulatorUDID: String,
        axCachePolicy: AXCachePolicy,
        typeSubmissionMode: TypeSubmissionMode,
        typeChunkSize: Int,
        waitTimeout: TimeInterval = 0,
        pollInterval: TimeInterval = 0.25,
        fetchElements: @escaping ElementFetcher = { udid, logger in
            try await AccessibilityFetcher.fetchAccessibilityElements(for: udid, logger: logger)
        }
    ) {
        self.simulatorUDID = simulatorUDID
        self.axCachePolicy = axCachePolicy
        self.typeSubmissionMode = typeSubmissionMode
        self.typeChunkSize = typeChunkSize
        self.waitTimeout = waitTimeout
        self.pollInterval = pollInterval
        self.fetchElements = fetchElements
    }

    /// Marks a step boundary. `.perStep` drops its snapshot here so the
    /// next selector resolution refetches; `.perBatch` keeps the snapshot
    /// for the whole run and `.none` never caches in the first place.
    public func beginStep() {
        if axCachePolicy == .perStep {
            cachedRoots = nil
        }
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
}