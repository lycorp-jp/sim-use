// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation

/// Resolves the tap / long-press coordinate forms — `--point x,y` or
/// the two `-x` / `-y` flags — into a single point. Shared by every
/// tap surface (top-level, `ios`, `android`, iOS batch) so the
/// exclusivity and range rules cannot drift apart. Mirrors
/// `SwipeCoordinateResolver`.
public enum TapCoordinateResolver {
    /// Returns the resolved point, or `nil` when no coordinate form
    /// was supplied (the caller falls through to alias / selector
    /// targeting). Throws `ValidationError` for partial or mixed
    /// forms and for out-of-range values (negative, non-finite, or
    /// absurdly large).
    public static func resolve(
        x: Double?,
        y: Double?,
        point: CoordinatePair?
    ) throws -> CoordinatePair? {
        if point != nil && (x != nil || y != nil) {
            throw ValidationError("Specify only one tap coordinate form: --point x,y or both -x/-y.")
        }
        if (x != nil) != (y != nil) {
            throw ValidationError("Both -x and -y must be provided together.")
        }

        let resolved: CoordinatePair
        if let point {
            resolved = point
        } else if let x, let y {
            resolved = CoordinatePair(x: x, y: y)
        } else {
            return nil
        }
        try validateRange(resolved)
        return resolved
    }

    /// Same range rules as `SwipeCoordinateResolver.validateRange`,
    /// minus the start≠end requirement (a tap is one point). The
    /// finite check matters for `-x`/`-y`: ArgumentParser's `Double`
    /// happily parses `inf`/`nan`, and the ≤ bound keeps a
    /// fat-fingered `1e19` from trapping the Double→Int conversion
    /// on the Android forward path.
    private static func validateRange(_ point: CoordinatePair) throws {
        let values = [point.x, point.y]
        guard values.allSatisfy({ $0.isFinite }) else {
            throw ValidationError("Coordinates must be finite numbers.")
        }
        guard values.allSatisfy({ $0 >= 0 }) else {
            throw ValidationError("Coordinates must be non-negative values.")
        }
        guard values.allSatisfy({ $0 <= SwipeCoordinateResolver.maximumCoordinate }) else {
            throw ValidationError("Coordinates must be at most \(Int(SwipeCoordinateResolver.maximumCoordinate)).")
        }
    }
}
