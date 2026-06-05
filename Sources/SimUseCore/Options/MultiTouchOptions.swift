// SPDX-License-Identifier: Apache-2.0
import ArgumentParser

/// Shared multi-finger flag declaration consumed by `tap` and
/// `long-press` (top-level + iOS + Android sub-commands). Centralised so
/// flag names, help text, and the finger-2 placement rule stay in
/// lockstep across every surface.
///
/// `--fingers 2` engages the two-finger path. Finger 1 is whatever the
/// host verb resolved (selector / alias / explicit -x/-y). Finger 2 is
/// placed by one of:
///
/// - explicit `--x2 N --y2 M` (both required, absolute pixels), or
/// - `--finger-distance D` (default 50 pt), where finger 2 sits at
///   `(finger1.x + D, finger1.y)` — i.e. D points to the right.
///
/// Direction is fixed to the x-axis; users who need vertical pairing
/// pass `--x2/--y2` explicitly. Matches the plan's D3 decision.
public struct MultiTouchOptions: ParsableArguments {
    @Option(
        name: .customLong("fingers"),
        help: "Number of fingers in the gesture. Defaults to 1 (single-touch). Pass 2 to dispatch a two-finger tap / long-press via the multi-touch HID primitive (iOS) or a two-stroke `/gesture` (Android)."
    )
    public var fingers: Int = 1

    @Option(
        name: .customLong("x2"),
        help: "Second finger X coordinate (pixels). Both --x2 and --y2 must be supplied together to position finger 2 explicitly; otherwise --finger-distance controls placement. Only meaningful when --fingers 2."
    )
    public var x2: Double?

    @Option(
        name: .customLong("y2"),
        help: "Second finger Y coordinate (pixels). See --x2."
    )
    public var y2: Double?

    @Option(
        name: .customLong("finger-distance"),
        help: "Distance from finger 1 to finger 2 along the x-axis in points. Default 50. Ignored when both --x2 and --y2 are supplied."
    )
    public var fingerDistance: Double = 50.0

    public init() {}

    /// Resolve finger 2's position given the resolved finger 1 point.
    /// Returns `(x, y)` directly if both `--x2` and `--y2` were
    /// supplied; otherwise applies the `--finger-distance` offset on
    /// the x-axis.
    public func fingerTwoPoint(forFinger1 finger1: (x: Double, y: Double)) -> (x: Double, y: Double) {
        if let x2, let y2 {
            return (x: x2, y: y2)
        }
        return (x: finger1.x + fingerDistance, y: finger1.y)
    }

    /// Centralised validation. Top-level forwarders call this from
    /// `validate()` so user-facing errors fire before any backend
    /// dispatch.
    public func validate() throws {
        guard fingers == 1 || fingers == 2 else {
            throw ValidationError("--fingers must be 1 or 2 (got \(fingers)). Three-or-more-finger gestures are not yet supported.")
        }
        // Asymmetric provision is almost always a typo: --x2 alone or
        // --y2 alone would silently fall through to the
        // finger-distance default and miss the user's intent.
        if (x2 == nil) != (y2 == nil) {
            throw ValidationError("--x2 and --y2 must be supplied together (or omitted together so --finger-distance controls placement).")
        }
        if let x2, x2 < 0 {
            throw ValidationError("--x2 must be non-negative.")
        }
        if let y2, y2 < 0 {
            throw ValidationError("--y2 must be non-negative.")
        }
        guard fingerDistance > 0 && fingerDistance <= 4000 else {
            throw ValidationError("--finger-distance must be between 1 and 4000 points.")
        }
        if fingers == 1 {
            // --x2/--y2/--finger-distance are silently accepted (no-op)
            // in 1-finger mode so users can flip `--fingers` without
            // also having to strip the placement flags. The validator
            // only catches the asymmetric --x2-only / --y2-only typo
            // above, which is wrong regardless of finger count.
        }
    }
}