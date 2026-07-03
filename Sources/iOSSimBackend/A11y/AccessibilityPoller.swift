// SPDX-License-Identifier: Apache-2.0
import Foundation

@MainActor
public struct AccessibilityPoller {
    /// Supplies AX roots for resolution. `forceRefresh: false` may serve
    /// a cached snapshot; `true` (poll ticks) must fetch a fresh one so
    /// delayed elements become visible.
    public typealias RootsProvider = @MainActor (_ forceRefresh: Bool) async throws -> [AccessibilityElement]

    public static func resolveWithPolling(
        query: AccessibilityQuery,
        simulatorUDID: String,
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        elementType: String? = nil,
        frameFilter: AccessibilityTargetResolver.FrameFilter? = nil,
        rootsProvider: RootsProvider? = nil,
        logger: SimUseLogger
    ) async throws -> (x: Double, y: Double) {
        // Non-batch callers pass no provider and keep the historical
        // fetch-every-time behaviour; batch passes the BatchContext cache.
        let fetchRoots: RootsProvider = rootsProvider ?? { _ in
            try await AccessibilityFetcher.fetchAccessibilityElements(for: simulatorUDID, logger: logger)
        }

        let roots = try await fetchRoots(false)
        do {
            return try AccessibilityTargetResolver.resolveCenterPoint(roots: roots, query: query, elementType: elementType, frameFilter: frameFilter)
        } catch let error as ElementResolutionError where error.isRetryableDuringWait && waitTimeout > 0 {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(waitTimeout)

            var lastError = error
            while clock.now < deadline {
                logger.info().log("Element not resolved (\(lastError.isNotFound ? "not found" : "ambiguous")), retrying in \(pollInterval)s…")
                try await Task.sleep(for: .seconds(pollInterval))

                let freshRoots = try await fetchRoots(true)
                do {
                    return try AccessibilityTargetResolver.resolveCenterPoint(roots: freshRoots, query: query, elementType: elementType, frameFilter: frameFilter)
                } catch let retryError as ElementResolutionError where retryError.isRetryableDuringWait {
                    lastError = retryError
                    continue
                }
            }

            throw lastError
        }
    }
}