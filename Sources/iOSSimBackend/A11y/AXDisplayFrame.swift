// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Single definition of "the screen" for code that measures against
/// display bounds derived from an AX snapshot (the full-screen tap
/// advisory denominator, `--frame` relative-bound resolution).
///
/// Application-typed roots are the candidate set — the same rule
/// `OutlineFormatter.pickRoot` applies when `describe-ui` renders the
/// `(WxH)` screen header — and the largest positive-area frame among
/// them wins, because root order is not guaranteed (keyboard / alert
/// windows can precede the app). Trees without a usable
/// Application-typed frame fall back to the largest positive-area
/// root of any type rather than trusting `roots.first`.
public enum AXDisplayFrame {
    public static func frame(in roots: [AccessibilityElement]) -> AccessibilityElement.Frame? {
        let usable = roots.compactMap { root -> (isApplication: Bool, frame: AccessibilityElement.Frame)? in
            guard let frame = root.frame, frame.width > 0, frame.height > 0 else { return nil }
            return (root.type == "Application", frame)
        }
        let applications = usable.filter(\.isApplication)
        let pool = applications.isEmpty ? usable : applications
        return pool.max { area($0.frame) < area($1.frame) }?.frame
    }

    private static func area(_ frame: AccessibilityElement.Frame) -> Double {
        frame.width * frame.height
    }
}
