// SPDX-License-Identifier: Apache-2.0
import FBSimulatorControl

// FBSimulatorHIDEvent is a pure value tree (coordinates, key codes,
// delays, nested composites) that upstream did not declare Sendable —
// public types get no implicit conformance. HID events cross a @Sendable
// boundary in the send-deadline path, so declare the conformance here.
extension FBSimulatorHIDEvent: @retroactive @unchecked Sendable {}
