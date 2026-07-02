// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Advisory for the case where a selector resolves to an element that covers
/// almost the whole screen. Frameworks that render to a canvas (e.g. Flutter)
/// wrap large regions in a single accessibility element whose frame spans the
/// display; a `--label`/`--value`/`--label-contains` match on that wrapper taps
/// the *screen centre*, silently missing the control the agent meant to hit.
/// We surface a non-fatal `[i]` line so the tap still happens (back-compat) but
/// the agent is told to use a more specific selector or explicit coordinates.
///
/// The decision is pure and unit-tested; emission is a stderr side-effect at
/// the resolver so it never corrupts `--json` stdout.
public enum FullScreenTapAdvisory {
    /// Area fraction of the screen at or above which we warn.
    public static let threshold = 0.9

    /// Returns an advisory line when `matched` covers at least `threshold` of
    /// `screen` by area. Returns nil when either frame is missing/degenerate or
    /// the element is comfortably smaller than the screen.
    public static func message(
        matched: AccessibilityElement.Frame,
        screen: AccessibilityElement.Frame?,
        query: String
    ) -> String? {
        guard let screen, screen.width > 0, screen.height > 0 else { return nil }
        guard matched.width > 0, matched.height > 0 else { return nil }
        let screenArea = screen.width * screen.height
        let matchedArea = matched.width * matched.height
        let fraction = matchedArea / screenArea
        guard fraction >= threshold else { return nil }
        let pct = Int((fraction * 100).rounded())
        return "[i] The element matching '\(query)' covers ~\(pct)% of the screen; "
            + "tapping its centre may hit a full-screen wrapper rather than the intended "
            + "control. Use a more specific selector (positional @N/#N) or explicit "
            + "coordinates (-x/-y)."
    }
}
