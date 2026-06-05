// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation

/// Preset gesture pattern shared by both the iOS HID path and the
/// Android bridge dispatch. The coordinate math is platform-agnostic
/// (pure functions of screen size + preset case) so the enum lives in
/// SimUseCore and is consumed by `IOSSimGestureCommand` /
/// `AndroidGestureCommand` / the cross-platform `Gesture` forwarder
/// from the same place.
///
/// Single-finger presets (scroll/edge) emit a one-element `[Stroke]`
/// with curve `.linear`. Two-finger presets (pinch / rotate) emit a
/// two-element array — finger 1 at index 0, finger 2 at index 1 —
/// with curve `.linear` for pinch and `.arc` for rotate. Callers branch
/// on `isMultiTouch` to decide whether to dispatch through the single-
/// touch or multi-touch path.
public enum GesturePreset: String, CaseIterable, ExpressibleByArgument, Sendable {
    case scrollUp = "scroll-up"
    case scrollDown = "scroll-down"
    case scrollLeft = "scroll-left"
    case scrollRight = "scroll-right"
    case swipeFromLeftEdge = "swipe-from-left-edge"
    case swipeFromRightEdge = "swipe-from-right-edge"
    case swipeFromTopEdge = "swipe-from-top-edge"
    case swipeFromBottomEdge = "swipe-from-bottom-edge"
    case pinchIn = "pinch-in"
    case pinchOut = "pinch-out"
    case rotateCw = "rotate-cw"
    case rotateCcw = "rotate-ccw"

    public var description: String {
        switch self {
        case .scrollUp:
            return "Scroll up in the center of screen"
        case .scrollDown:
            return "Scroll down in the center of screen"
        case .scrollLeft:
            return "Scroll left in the center of screen"
        case .scrollRight:
            return "Scroll right in the center of screen"
        case .swipeFromLeftEdge:
            return "Swipe from left edge to center (back navigation)"
        case .swipeFromRightEdge:
            return "Swipe from right edge to center (forward navigation)"
        case .swipeFromTopEdge:
            return "Swipe from top edge downward"
        case .swipeFromBottomEdge:
            return "Swipe from bottom edge upward"
        case .pinchIn:
            return "Pinch inward around screen center (zoom out)"
        case .pinchOut:
            return "Pinch outward around screen center (zoom in)"
        case .rotateCw:
            return "Rotate two fingers clockwise around screen center"
        case .rotateCcw:
            return "Rotate two fingers counter-clockwise around screen center"
        }
    }

    /// One trajectory in a (possibly multi-finger) gesture. The two
    /// endpoints describe the start and end positions of one contact
    /// point. `curve` selects how the path between them is filled in:
    /// linear strokes draw a straight line, arc strokes walk around
    /// a circle so rotation gestures don't introduce a parasitic
    /// pinch (mid-trajectory chord-vs-radius distance shrink).
    ///
    /// Angles in `Curve.arc` are radians, with the convention that
    /// `+θ` rotates the finger from the +x axis toward the +y axis.
    /// Screen-space y grows downward, so a visually-clockwise rotation
    /// is `startAngle < endAngle`.
    public struct Stroke: Sendable, Equatable {
        public let startX: Double
        public let startY: Double
        public let endX: Double
        public let endY: Double
        public let curve: Curve

        public init(startX: Double, startY: Double, endX: Double, endY: Double, curve: Curve = .linear) {
            self.startX = startX
            self.startY = startY
            self.endX = endX
            self.endY = endY
            self.curve = curve
        }

        public enum Curve: Sendable, Equatable {
            case linear
            case arc(centerX: Double, centerY: Double, radius: Double, startAngle: Double, endAngle: Double)
        }

        /// Position along the curve at progress `t ∈ [0, 1]`. Linear
        /// strokes interpolate the endpoints; arc strokes walk the
        /// configured circle so the radius stays constant.
        public func point(at t: Double) -> (x: Double, y: Double) {
            switch curve {
            case .linear:
                return (startX + (endX - startX) * t, startY + (endY - startY) * t)
            case .arc(let cx, let cy, let radius, let startAngle, let endAngle):
                let theta = startAngle + (endAngle - startAngle) * t
                return (cx + radius * cos(theta), cy + radius * sin(theta))
            }
        }
    }

    /// Multi-stroke shape for the preset. One element per finger, in
    /// finger-index order (finger 1 at index 0).
    public func strokes(
        screenWidth: Double = 390,
        screenHeight: Double = 844,
        scale: Double? = nil,
        angle: Double? = nil,
        centerX: Double? = nil,
        centerY: Double? = nil,
        radius: Double? = nil
    ) -> [Stroke] {
        let cx = centerX ?? screenWidth / 2
        let cy = centerY ?? screenHeight / 2
        // 20 px edge inset — see notes in the single-touch math below.
        let edgeMargin = 20.0
        let verticalScrollDistance = screenHeight / 4
        let horizontalScrollDistance = screenWidth / 4

        switch self {
        case .scrollUp:
            return [Stroke(startX: cx, startY: cy + verticalScrollDistance/2,
                           endX: cx, endY: cy - verticalScrollDistance/2)]
        case .scrollDown:
            return [Stroke(startX: cx, startY: cy - verticalScrollDistance/2,
                           endX: cx, endY: cy + verticalScrollDistance/2)]
        case .scrollLeft:
            return [Stroke(startX: cx + horizontalScrollDistance/2, startY: cy,
                           endX: cx - horizontalScrollDistance/2, endY: cy)]
        case .scrollRight:
            return [Stroke(startX: cx - horizontalScrollDistance/2, startY: cy,
                           endX: cx + horizontalScrollDistance/2, endY: cy)]
        case .swipeFromLeftEdge:
            return [Stroke(startX: edgeMargin, startY: cy,
                           endX: screenWidth - edgeMargin, endY: cy)]
        case .swipeFromRightEdge:
            return [Stroke(startX: screenWidth - edgeMargin, startY: cy,
                           endX: edgeMargin, endY: cy)]
        case .swipeFromTopEdge:
            return [Stroke(startX: cx, startY: edgeMargin,
                           endX: cx, endY: screenHeight - edgeMargin)]
        case .swipeFromBottomEdge:
            return [Stroke(startX: cx, startY: screenHeight - edgeMargin,
                           endX: cx, endY: edgeMargin)]
        case .pinchIn, .pinchOut:
            let r = radius ?? Self.recommendedRadius(screenWidth: screenWidth, screenHeight: screenHeight)
            let s = scale ?? (defaultScale ?? 1.0)
            // Fingers walk a horizontal diameter through (cx, cy).
            // Finger 1 on the +x side, finger 2 on the -x side.
            let f1Start = (x: cx + r, y: cy)
            let f1End = (x: cx + r * s, y: cy)
            let f2Start = (x: cx - r, y: cy)
            let f2End = (x: cx - r * s, y: cy)
            return [
                Stroke(startX: f1Start.x, startY: f1Start.y, endX: f1End.x, endY: f1End.y),
                Stroke(startX: f2Start.x, startY: f2Start.y, endX: f2End.x, endY: f2End.y),
            ]
        case .rotateCw, .rotateCcw:
            let r = radius ?? Self.recommendedRadius(screenWidth: screenWidth, screenHeight: screenHeight)
            let degrees = angle ?? (defaultAngle ?? 90)
            let sweep = degrees * .pi / 180.0
            // Screen-space y grows downward: a visually-clockwise
            // rotation corresponds to increasing θ (since sin θ adds
            // a positive y-offset as θ grows from 0).
            let signedSweep = (self == .rotateCw) ? sweep : -sweep
            let f1StartAngle = 0.0
            let f1EndAngle = f1StartAngle + signedSweep
            let f2StartAngle = Double.pi
            let f2EndAngle = f2StartAngle + signedSweep
            let f1Start = (x: cx + r * cos(f1StartAngle), y: cy + r * sin(f1StartAngle))
            let f1End = (x: cx + r * cos(f1EndAngle), y: cy + r * sin(f1EndAngle))
            let f2Start = (x: cx + r * cos(f2StartAngle), y: cy + r * sin(f2StartAngle))
            let f2End = (x: cx + r * cos(f2EndAngle), y: cy + r * sin(f2EndAngle))
            return [
                Stroke(
                    startX: f1Start.x, startY: f1Start.y,
                    endX: f1End.x, endY: f1End.y,
                    curve: .arc(centerX: cx, centerY: cy, radius: r,
                                startAngle: f1StartAngle, endAngle: f1EndAngle)
                ),
                Stroke(
                    startX: f2Start.x, startY: f2Start.y,
                    endX: f2End.x, endY: f2End.y,
                    curve: .arc(centerX: cx, centerY: cy, radius: r,
                                startAngle: f2StartAngle, endAngle: f2EndAngle)
                ),
            ]
        }
    }

    /// Convenience accessor for single-stroke callers (the existing
    /// scroll / edge-swipe presets and any forwarder that doesn't care
    /// about multi-touch). For multi-touch presets this returns the
    /// first finger's endpoints — callers that actually need both
    /// fingers must use `strokes(...)` directly.
    public func coordinates(screenWidth: Double = 390, screenHeight: Double = 844) -> (startX: Double, startY: Double, endX: Double, endY: Double) {
        let s = strokes(screenWidth: screenWidth, screenHeight: screenHeight)[0]
        return (s.startX, s.startY, s.endX, s.endY)
    }

    public var defaultDuration: Double {
        switch self {
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            return 0.5
        case .swipeFromLeftEdge, .swipeFromRightEdge, .swipeFromTopEdge, .swipeFromBottomEdge:
            return 0.3
        case .pinchIn, .pinchOut, .rotateCw, .rotateCcw:
            return 0.5
        }
    }

    public var defaultDelta: Double {
        switch self {
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            return 25.0
        case .swipeFromLeftEdge, .swipeFromRightEdge, .swipeFromTopEdge, .swipeFromBottomEdge:
            return 50.0
        case .pinchIn, .pinchOut, .rotateCw, .rotateCcw:
            // Multi-touch presets don't honour --delta; their iOS path
            // drives the HID stream via --steps/--step-ms instead.
            return 25.0
        }
    }

    /// Default scale (end-radius / start-radius) for pinch presets.
    /// `nil` for non-pinch presets.
    public var defaultScale: Double? {
        switch self {
        case .pinchOut: return 2.0
        case .pinchIn: return 0.5
        default: return nil
        }
    }

    /// Default rotation sweep in degrees for rotate presets. `nil` for
    /// non-rotate presets.
    public var defaultAngle: Double? {
        switch self {
        case .rotateCw, .rotateCcw: return 90.0
        default: return nil
        }
    }

    /// Default start radius for pinch / rotate presets (points).
    /// `nil` for non-multi-touch presets.
    public var defaultRadius: Double? {
        switch self {
        case .pinchIn, .pinchOut, .rotateCw, .rotateCcw: return 80.0
        default: return nil
        }
    }

    /// True when the preset emits more than one stroke (i.e. needs
    /// the multi-touch dispatch path).
    public var isMultiTouch: Bool {
        switch self {
        case .pinchIn, .pinchOut, .rotateCw, .rotateCcw: return true
        default: return false
        }
    }

    /// Display-aware start radius for pinch / rotate presets. iOS
    /// simulator sims sit around 390-430pt wide so the 80-pt floor
    /// dominates — behaviour unchanged. Android emulators / phones
    /// at 1080-1440px get a proportionally larger radius (162-216px)
    /// so the finger spread crosses stock recogniser thresholds
    /// (Google Maps' rotate needed ~50dp in field tests).
    ///
    /// 15% of the smaller dimension is the working point: large
    /// enough to clear recogniser minimums on every density we've
    /// tested, small enough that pinch-out keeps both fingers inside
    /// the display up to `--scale 3.0` (max excursion = scale * r =
    /// 3 * 0.15 * min = 45% of the shorter side, 5% edge margin).
    /// Above scale 3 users must pass `--radius` explicitly or the
    /// Android `assertPointsFit` check will reject the gesture.
    public static func recommendedRadius(screenWidth: Double, screenHeight: Double) -> Double {
        max(80.0, min(screenWidth, screenHeight) * 0.15)
    }

    /// Display-aware default duration for rotate presets. Holds the
    /// gesture's angular velocity at ~180°/sec — the empirical
    /// sweet spot where iOS `UIRotationGestureRecognizer` lands
    /// exactly on the requested angle and Android `dispatchGesture`'s
    /// internal smoothing tracks closely enough for the result to be
    /// usable (mild overshoot on large sweeps).
    ///
    /// Above ~360°/sec iOS overshoots via inertia (we measured a
    /// 270°/0.5s sweep landing at ~360°) and Android undershoots
    /// hard (~210° instead of 270°). Below the floor (90° default)
    /// the formula returns the baseline `defaultDuration` so
    /// `sim-use gesture rotate-cw` with no flags is unchanged.
    ///
    /// Non-rotate presets return `defaultDuration` regardless of
    /// `angle`. Pinch's failure mode is the opposite — long
    /// durations trip recogniser-side long-press alternatives —
    /// so we keep its 0.5s baseline and don't auto-extend.
    public func recommendedDuration(angle: Double?) -> Double {
        switch self {
        case .rotateCw, .rotateCcw:
            let a = abs(angle ?? defaultAngle ?? 90)
            return max(defaultDuration, a / 180.0)
        default:
            return defaultDuration
        }
    }

    /// Shared option validation for the `gesture` verb. Lives in
    /// SimUseCore so both `IOSSimGestureCommand` and
    /// `AndroidGestureCommand` (which cannot import each other) can
    /// reuse one set of rules; the top-level cross-platform
    /// forwarder calls this directly as well. Throws
    /// `ArgumentParser.ValidationError` so subcommands can surface
    /// the messages without translation.
    public static func validateOptions(
        preset: GesturePreset,
        screenWidth: Double?,
        screenHeight: Double?,
        duration: Double?,
        delta: Double?,
        scale: Double?,
        angle: Double?,
        centerX: Double?,
        centerY: Double?,
        radius: Double?,
        steps: Int,
        stepMs: Int?,
        preDelay: Double?,
        postDelay: Double?
    ) throws {
        // Upper bounds are generous enough to cover modern phones,
        // foldables, and tablets on both platforms (Galaxy Tab S9 Ultra
        // is 1848×2960, iPad Pro 12.9 is 2048×2732). On Android we
        // auto-detect the real display when these are omitted, so the
        // bounds here are purely a sanity check on explicit user input.
        if let screenWidth {
            guard screenWidth > 0 && screenWidth <= 4000 else {
                throw ValidationError("Screen width must be between 1 and 4000 points.")
            }
        }
        if let screenHeight {
            guard screenHeight > 0 && screenHeight <= 4000 else {
                throw ValidationError("Screen height must be between 1 and 4000 points.")
            }
        }
        if let duration {
            guard duration > 0 && duration <= 10.0 else {
                throw ValidationError("Duration must be between 0 and 10 seconds.")
            }
        }
        if let delta {
            guard delta > 0 && delta <= 200 else {
                throw ValidationError("Delta must be between 1 and 200 pixels.")
            }
        }
        if let preDelay {
            guard preDelay >= 0 && preDelay <= 10.0 else {
                throw ValidationError("Pre-delay must be between 0 and 10 seconds.")
            }
        }
        if let postDelay {
            guard postDelay >= 0 && postDelay <= 10.0 else {
                throw ValidationError("Post-delay must be between 0 and 10 seconds.")
            }
        }
        if let scale {
            guard scale > 0 && scale <= 10.0 else {
                throw ValidationError("--scale must be between 0 and 10.")
            }
        }
        if let angle {
            guard abs(angle) <= 720 else {
                throw ValidationError("--angle must be within ±720 degrees.")
            }
        }
        if let radius {
            guard radius > 0 && radius <= 2000 else {
                throw ValidationError("--radius must be between 1 and 2000 pixels.")
            }
        }
        if let centerX {
            guard centerX >= 0 else {
                throw ValidationError("--center-x must be non-negative.")
            }
        }
        if let centerY {
            guard centerY >= 0 else {
                throw ValidationError("--center-y must be non-negative.")
            }
        }
        guard steps >= 1 else {
            throw ValidationError("--steps must be ≥ 1.")
        }
        if let stepMs {
            guard stepMs >= 0 else {
                throw ValidationError("--step-ms must be ≥ 0.")
            }
        }
        if !preset.isMultiTouch {
            if scale != nil {
                throw ValidationError("--scale only applies to pinch presets.")
            }
            if angle != nil {
                throw ValidationError("--angle only applies to rotate presets.")
            }
        } else {
            // Pinch presets don't use --angle, rotate presets don't use --scale.
            switch preset {
            case .pinchIn, .pinchOut:
                if angle != nil {
                    throw ValidationError("--angle does not apply to \(preset.rawValue); did you mean --scale?")
                }
            case .rotateCw, .rotateCcw:
                if scale != nil {
                    throw ValidationError("--scale does not apply to \(preset.rawValue); did you mean --angle?")
                }
            default:
                break
            }
        }
    }
}