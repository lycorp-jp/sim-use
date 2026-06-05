// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBSimulatorControl

@MainActor
public enum BatchPrimitive {
    case hidMergeable(FBSimulatorHIDEvent)
    case hidBarrier(FBSimulatorHIDEvent)
    case hostSleep(TimeInterval)
    /// Arbitrary host-side work (e.g. `simctl pbcopy` for `paste` steps).
    /// Forces a flush of pending mergeable HID events first so visible
    /// ordering matches the step list. Receives the live HID `Session`
    /// and logger so the action can perform follow-up HID work without
    /// re-creating a connection.
    case hostAction(BatchHostAction)
}

/// Holder for `BatchPrimitive.hostAction`'s closure. Wrapping in a
/// nominal type keeps the enum discoverable in switches and avoids
/// having to spell out the closure signature at every use site.
@MainActor
public struct BatchHostAction {
    public let label: String
    public let perform: (HIDInteractor.Session, SimUseLogger) async throws -> Void

    public init(label: String, perform: @escaping (HIDInteractor.Session, SimUseLogger) async throws -> Void) {
        self.label = label
        self.perform = perform
    }
}

public struct BatchPlan {
    public let primitives: [BatchPrimitive]

    public init(primitives: [BatchPrimitive]) {
        self.primitives = primitives
    }
}