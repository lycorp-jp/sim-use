// SPDX-License-Identifier: Apache-2.0
import FBControlCore
import Foundation

/// The simulator's native screen size in points — the coordinate space the
/// HID layer normalizes against (`FBSimulatorIndigoHID` divides by
/// `deviceType.mainScreenSize` pixels), and the space AX point hit-tests
/// are interpreted in. iOS devices report this portrait-major.
public struct NativePortraitSize: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// Points = pixels / scale, matching the HID layer's own math
    /// (`FBSimulatorIndigoHID.screenRatioFromPoint:` multiplies points by
    /// scale before dividing by pixel size). `nil` when the target has no
    /// screen info or reports degenerate values.
    public init?(screenInfo: FBiOSTargetScreenInfo?) {
        guard let screenInfo, screenInfo.scale > 0,
              screenInfo.widthPixels > 0, screenInfo.heightPixels > 0
        else { return nil }
        self.width = Double(screenInfo.widthPixels) / Double(screenInfo.scale)
        self.height = Double(screenInfo.heightPixels) / Double(screenInfo.scale)
    }
}

/// The app's interface orientation relative to the native framebuffer.
///
/// AX element frames arrive in the app UI space (they rotate with the
/// interface); HID taps and AX point hit-tests are interpreted in the
/// fixed native framebuffer space. These are the four possible mappings,
/// measured empirically on iOS 26.5 (issue #34) with native portrait
/// W×H points and framebuffer point `f` ↔ UI point `u`:
///
///     portrait             u = f
///     portraitUpsideDown   u = (W−fx, H−fy)
///     landscapeRight       u = (fy, W−fx)      f = (W−uy, ux)
///     landscapeLeft        u = (H−fy, fx)      f = (uy, H−ux)
///
/// Names follow CoreSimulator's display descriptor (`simctl io enumerate`
/// "UI Orientation"), verified live against each Simulator rotate state:
/// one rotate-left from upright is Landscape Right, one rotate-right is
/// Landscape Left.
public enum DisplayOrientation: String, CaseIterable, Codable, Sendable {
    case portrait = "portrait"
    case portraitUpsideDown = "portrait-upside-down"
    case landscapeRight = "landscape-right"
    case landscapeLeft = "landscape-left"

    public var swapsDimensions: Bool {
        switch self {
        case .portrait, .portraitUpsideDown: return false
        case .landscapeRight, .landscapeLeft: return true
        }
    }

    /// The UI-space screen size for this orientation.
    public func uiSize(native: NativePortraitSize) -> (width: Double, height: Double) {
        swapsDimensions
            ? (width: native.height, height: native.width)
            : (width: native.width, height: native.height)
    }

    /// Framebuffer point → UI point.
    public func framebufferToUI(_ p: CGPoint, native: NativePortraitSize) -> CGPoint {
        let w = native.width
        let h = native.height
        let mapped: CGPoint
        switch self {
        case .portrait:
            mapped = p
        case .portraitUpsideDown:
            mapped = CGPoint(x: w - p.x, y: h - p.y)
        case .landscapeRight:
            mapped = CGPoint(x: p.y, y: w - p.x)
        case .landscapeLeft:
            mapped = CGPoint(x: h - p.y, y: p.x)
        }
        let ui = uiSize(native: native)
        return clamp(mapped, width: ui.width, height: ui.height)
    }

    /// UI point → framebuffer point (the coordinate to hand to HID or a
    /// point hit-test).
    public func uiToFramebuffer(_ p: CGPoint, native: NativePortraitSize) -> CGPoint {
        let w = native.width
        let h = native.height
        let mapped: CGPoint
        switch self {
        case .portrait:
            mapped = p
        case .portraitUpsideDown:
            mapped = CGPoint(x: w - p.x, y: h - p.y)
        case .landscapeRight:
            mapped = CGPoint(x: w - p.y, y: p.x)
        case .landscapeLeft:
            mapped = CGPoint(x: p.y, y: h - p.x)
        }
        return clamp(mapped, width: w, height: h)
    }

    /// The 180° image of an on-screen edge point lands exactly on W (or
    /// H), one point past the addressable range — hit-tests there return
    /// nil and HID would tap off-screen. Clamp to the half-open range
    /// [0, limit) so edge elements stay reachable.
    private func clamp(_ p: CGPoint, width: Double, height: Double) -> CGPoint {
        CGPoint(
            x: min(max(p.x, 0), width.nextDown),
            y: min(max(p.y, 0), height.nextDown)
        )
    }
}
