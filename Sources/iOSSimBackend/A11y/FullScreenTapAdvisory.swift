// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Warns when a selector resolves to a near-display-sized element. Canvas
/// frameworks can expose a full-screen wrapper whose center is not the control
/// the user meant to tap.
public enum FullScreenTapAdvisory {
    public static let threshold = 0.9

    public static func advisory(
        matched: AccessibilityElement.Frame,
        roots: [AccessibilityElement],
        query: String
    ) -> CommandAdvisory? {
        guard let screen = AXDisplayFrame.frame(in: roots),
              let message = message(matched: matched, screen: screen, query: query)
        else { return nil }
        return CommandAdvisory(kind: .fullScreenTapTarget, message: message)
    }

    public static func message(
        matched: AccessibilityElement.Frame,
        screen: AccessibilityElement.Frame,
        query: String
    ) -> String? {
        guard screen.width > 0, screen.height > 0 else { return nil }
        guard matched.width > 0, matched.height > 0 else { return nil }
        let fraction = (matched.width * matched.height) / (screen.width * screen.height)
        guard fraction >= threshold else { return nil }
        let pct = Int((min(fraction, 1.0) * 100).rounded())
        return "The element matching '\(query)' covers ~\(pct)% of the screen; " +
            "tapping its center may hit a full-screen wrapper rather than the intended control. " +
            "Use a positional @N/#N alias or explicit -x/-y coordinates."
    }
}
