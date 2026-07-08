// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import Testing

// Pins the `--point` fast-path decision rule: a single identity hit-test
// may settle the orientation only when exactly one candidate maps the
// probe point into the returned frame. The pre-fix rule gave portrait
// the tie, so on a rotated device a raw hit landing on a large frame
// (background, window) confidently returned the wrong element with
// `orientation: portrait` and no advisory (issue #34 review finding).

private let native = NativePortraitSize(width: 834, height: 1210)

@Suite("Point-query sole-orientation decision")
struct PointQueryOrientationTests {
    // Probe point (100,100) projects to:
    //   portrait             (100, 100)
    //   portrait-upside-down (734, 1110)
    //   landscape-right      (100, 734)
    //   landscape-left       (1110, 100)
    private let probePoint = CGPoint(x: 100, y: 100)

    @Test("small frame around the portrait projection settles portrait")
    func portraitUnique() {
        let frame = CGRect(x: 80, y: 80, width: 50, height: 50)
        let result = OrientationCalibrator.soleOrientation(
            mapping: probePoint, into: frame, native: native
        )
        #expect(result == .portrait)
    }

    @Test("small frame around a landscape projection settles that landscape")
    func landscapeUnique() {
        let frame = CGRect(x: 90, y: 700, width: 60, height: 60)
        let result = OrientationCalibrator.soleOrientation(
            mapping: probePoint, into: frame, native: native
        )
        #expect(result == .landscapeRight)
    }

    @Test("a full-screen frame containing every projection is ambiguous")
    func fatFrameAmbiguous() {
        // Regression: portrait used to win this tie.
        let frame = CGRect(x: 0, y: 0, width: 834, height: 1210)
        let result = OrientationCalibrator.soleOrientation(
            mapping: probePoint, into: frame, native: native
        )
        #expect(result == nil)
    }

    @Test("near-center probes are ambiguous even in small frames")
    func nearCenterAmbiguous() {
        // At the screen center every mapping projects onto (almost)
        // the same point, so containment proves nothing.
        let center = CGPoint(x: 417, y: 605)
        let frame = CGRect(x: 400, y: 590, width: 40, height: 30)
        let result = OrientationCalibrator.soleOrientation(
            mapping: center, into: frame, native: native
        )
        #expect(result == nil)
    }

    @Test("a frame containing no projection is ambiguous, not portrait")
    func inconsistentHitAmbiguous() {
        let frame = CGRect(x: 500, y: 500, width: 10, height: 10)
        let result = OrientationCalibrator.soleOrientation(
            mapping: probePoint, into: frame, native: native
        )
        #expect(result == nil)
    }

    @Test("containment honors the calibration slack")
    func slackHonored() {
        // Frame edge 1 pt away from the portrait projection — inside
        // the ±2 pt slack, so still a unique portrait match.
        let frame = CGRect(x: 101, y: 101, width: 40, height: 40)
        let result = OrientationCalibrator.soleOrientation(
            mapping: probePoint, into: frame, native: native
        )
        #expect(result == .portrait)
    }
}
