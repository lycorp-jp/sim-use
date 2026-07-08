// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import Testing

// Regression for issue #34's quadtree symptom: on a rotated device the
// recovery probes (framebuffer space) and the AX frames (UI space)
// disagree, so entire off-center containers — the Settings sidebar in the
// live reproduction — silently vanish from the outline. The fix routes
// every probe through the orientation calibration exactly as
// `AccessibilityFetcher.fetchAccessibilityInfo` composes it.

private let native = NativePortraitSize(width: 400, height: 800)
private let sidebarFrame = CGRect(x: 10, y: 100, width: 150, height: 600)

/// Sidebar rows in UI space, aligned with the default 80 pt seed-row grid
/// so first-pass probe centers land inside them.
private let sidebarItems: [CGRect] = (0..<6).map { i in
    CGRect(x: 20, y: 110 + Double(i) * 80, width: 130, height: 60)
}

private func axFrame(_ r: CGRect) -> String {
    "{{\(r.minX), \(r.minY)}, {\(r.width), \(r.height)}}"
}

private func frameDict(_ r: CGRect) -> [String: Any] {
    ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
}

private func fixtureTree() -> NSArray {
    let emptySidebar: [String: Any] = [
        "role": "AXGroup",
        "AXLabel": "Sidebar",
        "AXFrame": axFrame(sidebarFrame),
        "frame": frameDict(sidebarFrame),
        "children": [] as [[String: Any]],
    ]
    let app: [String: Any] = [
        "role": "AXApplication",
        "type": "Application",
        "AXLabel": "TestApp",
        "AXFrame": axFrame(CGRect(x: 0, y: 0, width: 400, height: 800)),
        "frame": frameDict(CGRect(x: 0, y: 0, width: 400, height: 800)),
        "children": [emptySidebar],
    ]
    return [app] as NSArray
}

/// The device: interprets probe input in framebuffer space, returns
/// frames in UI space — ground truth is a 180°-rotated iPad-like screen.
private func deviceProbe(_ framebufferPoint: CGPoint) -> [String: Any]? {
    let ui = DisplayOrientation.portraitUpsideDown.framebufferToUI(framebufferPoint, native: native)
    guard let (index, hit) = sidebarItems.enumerated().first(where: { $0.element.contains(ui) })
    else { return nil }
    return [
        "role": "AXButton",
        "AXLabel": "Item \(index)",
        "AXFrame": axFrame(hit),
        "frame": frameDict(hit),
    ]
}

@MainActor
private func recoveredSidebarChildren(
    probe: @escaping CollapsedChildrenRecovery.PointProbe
) async throws -> [[String: Any]] {
    let result = try await CollapsedChildrenRecovery.recover(
        in: fixtureTree(),
        probe: probe,
        logger: SimUseLogger(writeToStdErr: false)
    )
    let roots = try #require(result as? [[String: Any]])
    let app = try #require(roots.first)
    let appChildren = try #require(app["children"] as? [[String: Any]])
    let sidebar = try #require(appChildren.first)
    return (sidebar["children"] as? [[String: Any]]) ?? []
}

@MainActor
@Suite("Orientation recovery regression")
struct OrientationRecoveryTests {
    @Test("raw probes lose the sidebar on a 180° device")
    func rawProbesLoseSidebar() async throws {
        let children = try await recoveredSidebarChildren { deviceProbe($0) }
        #expect(children.isEmpty)
    }

    @Test("calibrated probes recover the sidebar on a 180° device")
    func calibratedProbesRecoverSidebar() async throws {
        let calibration = OrientationCalibration(
            orientation: .portraitUpsideDown,
            native: native,
            probesUsed: 1,
            advisory: nil
        )
        // Exactly the wrapper fetchAccessibilityInfo installs for
        // non-identity calibrations.
        let children = try await recoveredSidebarChildren { deviceProbe(calibration.hidCGPoint($0)) }
        #expect(children.count >= 3)
        for child in children {
            let rect = try #require(OrientationCalibrator.frameRect(of: child))
            #expect(sidebarFrame.contains(CGPoint(x: rect.midX, y: rect.midY)))
            #expect(child["synthesized"] as? Bool == true)
        }
    }
}
