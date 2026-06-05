// SPDX-License-Identifier: Apache-2.0
import Foundation

@MainActor
public struct AccessibilityPoller {
    public static func resolveWithPolling(
        query: AccessibilityQuery,
        simulatorUDID: String,
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        elementType: String? = nil,
        frameFilter: AccessibilityTargetResolver.FrameFilter? = nil,
        logger: SimUseLogger
    ) async throws -> (x: Double, y: Double) {
        let roots = try await AccessibilityFetcher.fetchAccessibilityElements(for: simulatorUDID, logger: logger)
        do {
            return try AccessibilityTargetResolver.resolveCenterPoint(roots: roots, query: query, elementType: elementType, frameFilter: frameFilter)
        } catch let error as ElementResolutionError where error.isNotFound && waitTimeout > 0 {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(waitTimeout)

            var lastError = error
            while clock.now < deadline {
                logger.info().log("Element not found, retrying in \(pollInterval)s…")
                try await Task.sleep(for: .seconds(pollInterval))

                let freshRoots = try await AccessibilityFetcher.fetchAccessibilityElements(for: simulatorUDID, logger: logger)
                do {
                    return try AccessibilityTargetResolver.resolveCenterPoint(roots: freshRoots, query: query, elementType: elementType, frameFilter: frameFilter)
                } catch let retryError as ElementResolutionError where retryError.isNotFound {
                    lastError = retryError
                    continue
                }
            }

            throw lastError
        }
    }
}