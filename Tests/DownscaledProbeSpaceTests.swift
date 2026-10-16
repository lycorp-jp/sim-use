// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import Testing

// iPhone 12 mini: UI space 375x812, pixels / scale 360x780. The AX
// hit-test consumes UI-METRIC points on native-portrait AXES (verified
// live on iOS 26.4: querying the un-scaled UI point returns the element
// at that point, while the pixels/scale-shrunk point lands ~4% off),
// whereas HID dispatch normalizes against pixels/scale. These tests pin
// the two transforms apart.
private let mini = NativePortraitSize(width: 360, height: 780)
private let miniScale = UIPointScale(native: mini, uiPortrait: (width: 375, height: 812))!

private func miniCalibration(_ orientation: DisplayOrientation) -> OrientationCalibration {
    OrientationCalibration(
        orientation: orientation,
        native: mini,
        uiScale: miniScale,
        probesUsed: 1,
        advisory: nil
    )
}

@Suite("Probe vs HID space on display-downscaled devices")
struct DownscaledProbeSpaceTests {
    @Test("portrait probes pass through un-scaled")
    func portraitProbeIdentity() {
        // The Settings toolbar Dictate button center: the probe must
        // query exactly this UI point — shrinking it into the HID metric
        // would hit the neighbouring row.
        let p = miniCalibration(.portrait).probeCGPoint(CGPoint(x: 317.5, y: 760))
        #expect(p == CGPoint(x: 317.5, y: 760))
    }

    @Test("portrait HID dispatch carries the metric scale")
    func portraitHIDScales() {
        let calibration = miniCalibration(.portrait)
        #expect(!calibration.isIdentity)
        let p = calibration.hidCGPoint(CGPoint(x: 187.5, y: 674.5))
        #expect(abs(p.x - 180) < 0.001)
        #expect(abs(p.y - 674.5 * 780 / 812) < 0.001)
    }

    @Test("landscape probes rotate on the UI-sized canvas, HID on the scaled one")
    func landscapeProbeAndHIDDiverge() {
        let ui = CGPoint(x: 100, y: 200)
        // Axes only, on the 375x812 canvas: (375 − 200, 100).
        let probe = miniCalibration(.landscapeRight).probeCGPoint(ui)
        #expect(abs(probe.x - 175) < 0.001)
        #expect(abs(probe.y - 100) < 0.001)
        // HID additionally shrinks into the 360x780 metric.
        let hid = miniCalibration(.landscapeRight).hidCGPoint(ui)
        #expect(abs(hid.x - (360 - 200 * 360 / 375)) < 0.001)
        #expect(abs(hid.y - 100 * 780 / 812) < 0.001)
    }

    @Test("wrappedProbe forwards portrait probe points untouched")
    @MainActor
    func wrappedProbePortrait() async throws {
        final class Box: @unchecked Sendable { var received: CGPoint? }
        let box = Box()
        let probe = miniCalibration(.portrait).wrappedProbe { p in
            box.received = p
            return nil
        }
        _ = try await probe(CGPoint(x: 317.5, y: 760))
        #expect(box.received == CGPoint(x: 317.5, y: 760))
    }
}
