// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

@MainActor
public struct AccessibilityPoller {
    /// Supplies AX roots for resolution. `forceRefresh: false` may serve
    /// a cached snapshot; `true` (poll ticks) must fetch a fresh one so
    /// delayed elements become visible.
    public typealias RootsProvider = @MainActor (_ forceRefresh: Bool) async throws -> [AccessibilityElement]

    /// Roots plus the orientation calibration of the fetch that produced
    /// them, so HID consumers can transform the resolved UI-space center
    /// into the framebuffer space taps are dispatched in (issue #34).
    public typealias CalibratedRootsProvider = @MainActor (_ forceRefresh: Bool) async throws
        -> (roots: [AccessibilityElement], calibration: OrientationCalibration?)

    /// A resolved element target together with the calibration to apply
    /// before handing the point to HID. `calibration` is nil when the
    /// roots provider did not calibrate (legacy providers).
    public struct ResolvedHIDTarget {
        public let target: AccessibilityTargetResolver.ResolvedTarget
        public let calibration: OrientationCalibration?

        /// UI-space center (what the user sees in the outline).
        public var ui: (x: Double, y: Double) { (x: target.x, y: target.y) }
        /// Framebuffer-space point to dispatch HID at.
        public var hid: (x: Double, y: Double) {
            calibration?.hidPoint(x: target.x, y: target.y) ?? ui
        }
        /// Resolution advisory merged with any calibration advisory.
        public var advisory: CommandAdvisory? {
            CommandAdvisory.merged([target.advisory, calibration?.advisory].compactMap { $0 })
        }
    }

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
        let target = try await resolveWithPollingTarget(
            query: query,
            simulatorUDID: simulatorUDID,
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            elementType: elementType,
            frameFilter: frameFilter,
            rootsProvider: rootsProvider,
            logger: logger
        )
        return (x: target.x, y: target.y)
    }

    public static func resolveWithPollingTarget(
        query: AccessibilityQuery,
        simulatorUDID: String,
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        elementType: String? = nil,
        frameFilter: AccessibilityTargetResolver.FrameFilter? = nil,
        rootsProvider: RootsProvider? = nil,
        logger: SimUseLogger
    ) async throws -> AccessibilityTargetResolver.ResolvedTarget {
        let adapted: CalibratedRootsProvider? = rootsProvider.map { provider in
            { force in (roots: try await provider(force), calibration: nil) }
        }
        return try await resolveWithPollingHIDTarget(
            query: query,
            simulatorUDID: simulatorUDID,
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            elementType: elementType,
            frameFilter: frameFilter,
            rootsProvider: adapted,
            logger: logger
        ).target
    }

    public static func resolveWithPollingHIDTarget(
        query: AccessibilityQuery,
        simulatorUDID: String,
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        elementType: String? = nil,
        frameFilter: AccessibilityTargetResolver.FrameFilter? = nil,
        rootsProvider: CalibratedRootsProvider? = nil,
        logger: SimUseLogger
    ) async throws -> ResolvedHIDTarget {
        // Non-batch callers pass no provider and keep the historical
        // fetch-every-time behaviour; batch passes the BatchContext cache.
        let fetchRoots: CalibratedRootsProvider = rootsProvider ?? { _ in
            try await AccessibilityFetcher.fetchAccessibilityElementsWithCalibration(for: simulatorUDID, logger: logger)
        }

        let (roots, calibration) = try await fetchRoots(false)
        do {
            let target = try AccessibilityTargetResolver.resolveTarget(roots: roots, query: query, elementType: elementType, frameFilter: frameFilter)
            return ResolvedHIDTarget(target: target, calibration: calibration)
        } catch let error as ElementResolutionError where error.isRetryableDuringWait && waitTimeout > 0 {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(waitTimeout)

            var lastError = error
            while clock.now < deadline {
                logger.info().log("Element not resolved (\(lastError.isNotFound ? "not found" : "ambiguous")), retrying in \(pollInterval)s…")
                try await Task.sleep(for: .seconds(pollInterval))

                let (freshRoots, freshCalibration) = try await fetchRoots(true)
                do {
                    let target = try AccessibilityTargetResolver.resolveTarget(roots: freshRoots, query: query, elementType: elementType, frameFilter: frameFilter)
                    return ResolvedHIDTarget(target: target, calibration: freshCalibration)
                } catch let retryError as ElementResolutionError where retryError.isRetryableDuringWait {
                    lastError = retryError
                    continue
                }
            }

            throw lastError
        }
    }
}
