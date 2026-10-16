// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

// A calibration taken from the describe-ui snapshot is used for UI-space
// coordinates only when hit-tests under it still find the snapshot's
// elements where the snapshot put them (docs/ai/010-display-routing, S3).
// The snapshot path reads no tree, so it has no other way to notice a
// display that changed (a Resize Mode session that started), a rotation
// or another screen.

private let native = NativePortraitSize(width: 402, height: 874)
private let screenArea = 402.0 * 874.0

// Small, off-center elements in portrait UI space.
private let elements: [CGRect] = [
    CGRect(x: 16, y: 120, width: 56, height: 56),
    CGRect(x: 330, y: 120, width: 56, height: 56),
    CGRect(x: 16, y: 780, width: 56, height: 56),
    CGRect(x: 330, y: 780, width: 56, height: 56),
]

private func calibration(_ orientation: DisplayOrientation) -> OrientationCalibration {
    OrientationCalibration(orientation: orientation, native: native, probesUsed: 0, advisory: nil)
}

/// A screen whose UI is in `truth` and shows `shown`: a hit-test at a
/// framebuffer point returns the shown element there, else the window.
private func screen(_ truth: DisplayOrientation, shown: [CGRect]) -> OrientationCalibrator.HitTestProbe {
    { point in
        let ui = truth.framebufferToUI(point, native: native)
        let rect = shown.first { $0.contains(ui) } ?? CGRect(x: 0, y: 0, width: 402, height: 874)
        return ["frame": ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]]
    }
}

@Suite("Snapshot calibration confirmation")
struct SnapshotConfirmationTests {
    @Test("the snapshot's elements are still in place")
    func confirmed() async {
        let ok = await OrientationCalibrator.confirms(
            calibration(.portrait), discriminators: elements, sceneArea: screenArea,
            probe: screen(.portrait, shown: elements))
        #expect(ok)
    }

    @Test("another display answers with a full-screen element (a session that started)")
    func otherDisplay() async {
        let ok = await OrientationCalibrator.confirms(
            calibration(.portrait), discriminators: elements, sceneArea: screenArea,
            probe: screen(.portrait, shown: []))
        #expect(!ok)
    }

    @Test("the device rotated since the snapshot")
    func rotated() async {
        // The four corners are point-symmetric, so the rotated screen
        // shows an element at every probed corner — just not the one the
        // snapshot put there.
        let ok = await OrientationCalibrator.confirms(
            calibration(.portrait), discriminators: elements, sceneArea: screenArea,
            probe: screen(.portraitUpsideDown, shown: elements))
        #expect(!ok)
    }

    @Test("no probe-able element confirms nothing")
    func noDiscriminators() async {
        let ok = await OrientationCalibrator.confirms(
            calibration(.portrait), discriminators: [CGRect(x: 0, y: 0, width: 402, height: 874)],
            sceneArea: screenArea, probe: screen(.portrait, shown: elements))
        #expect(!ok)
    }

    @Test("a probe error counts as a miss")
    func probeError() async {
        let ok = await OrientationCalibrator.confirms(
            calibration(.portrait), discriminators: elements, sceneArea: screenArea,
            probe: { _ in throw CLIError(errorDescription: "gone") })
        #expect(!ok)
    }

    @Test("one probe-able element needs one hit")
    func singleDiscriminator() async {
        let ok = await OrientationCalibrator.confirms(
            calibration(.portrait), discriminators: [elements[0]], sceneArea: screenArea,
            probe: screen(.portrait, shown: elements))
        #expect(ok)
    }

    @Test("the snapshot fits only the scene it was taken of", arguments: [
        (CGSize(width: 402, height: 874), CGSize(width: 402, height: 874), true),
        // A rotation swaps the sides; the probes decide the orientation.
        (CGSize(width: 874, height: 402), CGSize(width: 402, height: 874), true),
        // The iPhone Duo inner display: interface 951x669, panel-sized root.
        (CGSize(width: 951, height: 669), CGSize(width: 669, height: 951), true),
        // A Resize Mode session resized from 560x1200 to 560x667 (R161-01).
        (CGSize(width: 560, height: 1200), CGSize(width: 560, height: 667), false),
        (CGSize(width: 386, height: 678), CGSize(width: 466, height: 678), false),
    ])
    func sceneSize(snapshot: CGSize, root: CGSize, expected: Bool) {
        #expect(OrientationCalibrator.snapshotFits(screen: snapshot, rootSize: root) == expected)
    }

    @Test("an unknown root size does not fit")
    func unknownRoot() {
        #expect(!OrientationCalibrator.snapshotFits(screen: CGSize(width: 402, height: 874), rootSize: nil))
    }
}
