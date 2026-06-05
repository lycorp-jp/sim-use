// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBSimulatorControl

@MainActor
public struct BatchPlanRunner {
    public let session: HIDInteractor.Session
    public let logger: SimUseLogger

    public init(session: HIDInteractor.Session, logger: SimUseLogger) {
        self.session = session
        self.logger = logger
    }

    public func run(_ plan: BatchPlan) async throws {
        var pendingMergeable: [FBSimulatorHIDEvent] = []

        func flushPending() async throws {
            guard !pendingMergeable.isEmpty else { return }
            let event = pendingMergeable.count == 1 ? pendingMergeable[0] : FBSimulatorHIDEvent(events: pendingMergeable)
            try await HIDInteractor.performHIDEvent(event, in: session, logger: logger)
            pendingMergeable.removeAll(keepingCapacity: true)
        }

        for primitive in plan.primitives {
            switch primitive {
            case .hidMergeable(let event):
                pendingMergeable.append(event)
            case .hidBarrier(let event):
                try await flushPending()
                try await HIDInteractor.performHIDEvent(event, in: session, logger: logger)
            case .hostSleep(let seconds):
                try await flushPending()
                guard seconds > 0 else { continue }
                try await Task.sleep(for: .seconds(seconds))
            case .hostAction(let action):
                try await flushPending()
                logger.info().log("Running host action: \(action.label)")
                try await action.perform(session, logger)
            }
        }

        try await flushPending()
    }
}