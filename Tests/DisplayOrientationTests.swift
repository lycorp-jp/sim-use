// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import FBControlCore
import Foundation
import Testing

private let iPad = NativePortraitSize(width: 834, height: 1210)
private let iPhone = NativePortraitSize(width: 393, height: 852)

@Suite("DisplayOrientation transforms")
struct DisplayOrientationTransformTests {
    @Test("portrait is identity")
    func portraitIdentity() {
        let p = CGPoint(x: 170, y: 600)
        #expect(DisplayOrientation.portrait.framebufferToUI(p, native: iPad) == p)
        #expect(DisplayOrientation.portrait.uiToFramebuffer(p, native: iPad) == p)
    }

    // Measured on the live iPad (issue #34 verification): probing
    // framebuffer (170,600) under a 180° device returned the element whose
    // UI frame contains (664,610).
    @Test("180° mirrors both axes")
    func upsideDown() {
        let f = CGPoint(x: 170, y: 600)
        let u = DisplayOrientation.portraitUpsideDown.framebufferToUI(f, native: iPad)
        #expect(u == CGPoint(x: 664, y: 610))
        #expect(DisplayOrientation.portraitUpsideDown.uiToFramebuffer(u, native: iPad) == f)
    }

    // Measured: landscape-A device, framebuffer (770,332) hit the nav bar
    // whose UI-space location is (332,64); the working corrected tap for
    // UI (770,332) was framebuffer (502,770).
    @Test("landscape A maps u = (fy, W−fx)")
    func landscapeRight() {
        let f = CGPoint(x: 770, y: 332)
        let u = DisplayOrientation.landscapeRight.framebufferToUI(f, native: iPad)
        #expect(u == CGPoint(x: 332, y: 64))
        #expect(DisplayOrientation.landscapeRight.uiToFramebuffer(CGPoint(x: 770, y: 332), native: iPad)
            == CGPoint(x: 502, y: 770))
    }

    // Measured: landscape-B device, tap @About center UI (770,332) landed on
    // the VPN row at UI (878,770) because HID interpreted it in framebuffer
    // space — i.e. framebufferToUI(770,332) == (878,770). The corrected back
    // -button tap for UI (372,54) was framebuffer (54,838).
    @Test("landscape B maps u = (H−fy, fx)")
    func landscapeLeft() {
        let f = CGPoint(x: 770, y: 332)
        let u = DisplayOrientation.landscapeLeft.framebufferToUI(f, native: iPad)
        #expect(u == CGPoint(x: 878, y: 770))
        #expect(DisplayOrientation.landscapeLeft.uiToFramebuffer(CGPoint(x: 372, y: 54), native: iPad)
            == CGPoint(x: 54, y: 838))
    }

    @Test("round-trip is identity for every orientation", arguments: DisplayOrientation.allCases)
    func roundTrip(orientation: DisplayOrientation) {
        for native in [iPad, iPhone] {
            let ui = orientation.uiSize(native: native)
            for p in [
                CGPoint(x: 1, y: 1),
                CGPoint(x: 123.5, y: 47.25),
                CGPoint(x: ui.width / 2, y: ui.height / 2),
                CGPoint(x: ui.width - 1, y: ui.height - 1),
            ] {
                let f = orientation.uiToFramebuffer(p, native: native)
                let back = orientation.framebufferToUI(f, native: native)
                #expect(abs(back.x - p.x) < 0.0001)
                #expect(abs(back.y - p.y) < 0.0001)
            }
        }
    }

    @Test("uiSize swaps only for landscapes")
    func uiSizeSwap() {
        #expect(DisplayOrientation.portrait.uiSize(native: iPad) == (834, 1210))
        #expect(DisplayOrientation.portraitUpsideDown.uiSize(native: iPad) == (834, 1210))
        #expect(DisplayOrientation.landscapeRight.uiSize(native: iPad) == (1210, 834))
        #expect(DisplayOrientation.landscapeLeft.uiSize(native: iPad) == (1210, 834))
        #expect(DisplayOrientation.portrait.swapsDimensions == false)
        #expect(DisplayOrientation.landscapeRight.swapsDimensions == true)
    }

    @Test("edge points clamp inside the addressable framebuffer")
    func edgeClamping() {
        // The 180° image of the UI origin is exactly (W, H) — must clamp
        // just inside so hit-tests and HID stay on-screen.
        let f = DisplayOrientation.portraitUpsideDown.uiToFramebuffer(.zero, native: iPad)
        #expect(f.x < iPad.width && f.x > iPad.width - 0.001)
        #expect(f.y < iPad.height && f.y > iPad.height - 0.001)

        // Negative inputs clamp to zero rather than escaping the screen.
        let g = DisplayOrientation.portrait.uiToFramebuffer(CGPoint(x: -5, y: -5), native: iPad)
        #expect(g == .zero)

        // Landscape image of a UI edge point stays inside the portrait frame.
        let h = DisplayOrientation.landscapeRight.uiToFramebuffer(CGPoint(x: 0, y: 0), native: iPad)
        #expect(h.x < iPad.width && h.y >= 0)
    }
}

@Suite("NativePortraitSize")
struct NativePortraitSizeTests {
    @Test("screenInfo converts pixels to points via scale")
    func screenInfoConversion() {
        let info = FBiOSTargetScreenInfo(widthPixels: 1668, heightPixels: 2420, scale: 2.0)
        let size = NativePortraitSize(screenInfo: info)
        #expect(size == NativePortraitSize(width: 834, height: 1210))
    }

    @Test("nil and degenerate screenInfo are rejected")
    func degenerateScreenInfo() {
        #expect(NativePortraitSize(screenInfo: nil) == nil)
        #expect(NativePortraitSize(screenInfo: FBiOSTargetScreenInfo(widthPixels: 0, heightPixels: 2420, scale: 2)) == nil)
        #expect(NativePortraitSize(screenInfo: FBiOSTargetScreenInfo(widthPixels: 1668, heightPixels: 2420, scale: 0)) == nil)
    }
}
