// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
@testable import iOSSimBackend
import FBSimulatorControl
import Foundation
import SimUseCore
import Testing

// Unit coverage for touch and AX routing (docs/ai/010-display-routing, S2):
// the HID route and the fixed calibration of each routing display, and the
// scene placement of a scene smaller than its display. The expected
// numbers are the ones measured live in the plan (E4, E14, E29, E30).

private func topology(_ name: String) throws -> SimulatorDisplayTopology {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/display-topology/\(name)", withExtension: "json"))
    let output = DevicectlQueryOutput(terminationStatus: 0, stdout: try Data(contentsOf: url), stderr: Data())
    return try #require(SimulatorDisplayTopologyProbe.classify(output).topology)
}

private let session = ResizableAppSession(
    displayUniqueID: "7C42B556-2B95-4526-B558-C06CDA5AF3F7",
    displayName: "Resizable",
    preferredWidth: 560,
    preferredHeight: 874
)

private let quietLogger = SimUseLogger(writeToStdErr: false)

// MARK: - Addressing

@Suite("RoutingDisplay — HID route, AX display and fixed calibration")
struct RoutingDisplayAddressingTests {
    @Test("the main display keeps the historical path")
    func main() throws {
        #expect(RoutingDisplay.main.accessibilityDisplayID == 0)
        #expect(try RoutingDisplay.main.hidRoute() == nil)
        #expect(RoutingDisplay.main.fixedCalibration(sceneSize: nil) == nil)
    }

    @Test("the Duo inner display: target 3, its panel in pixels, rotation from CoreDevice")
    func secondary() throws {
        let inner = try #require(try topology("duo-open").activeIntegrated)
        let routing = RoutingDisplay.secondary(inner)
        #expect(routing.accessibilityDisplayID == 3)
        let route = try #require(try routing.hidRoute())
        #expect(route == FBSimulatorHIDDisplayRoute(digitizerTarget: 3, screenSize: CGSize(width: 2007, height: 2853), screenScale: 3))
        let calibration = try #require(routing.fixedCalibration(sceneSize: nil))
        #expect(calibration.orientation == .landscapeLeft)
        #expect(calibration.native == NativePortraitSize(width: 669, height: 951))
        #expect(calibration.probesUsed == 0)
        #expect(calibration.advisory == nil)
    }

    @Test("a UI point on the inner display reaches the measured digitizer ratio (E3, E4)")
    func secondaryRatio() throws {
        let inner = try #require(try topology("duo-open").activeIntegrated)
        let routing = RoutingDisplay.secondary(inner)
        let route = try #require(try routing.hidRoute())
        let calibration = try #require(routing.fixedCalibration(sceneSize: nil))
        // The "iOS version" row centre tapped in the spike, at rot90.
        let panel = calibration.hidCGPoint(CGPoint(x: 603.5, y: 179.66))
        let ratio = (x: Double(panel.x) * Double(route.screenScale) / route.screenSize.width,
                     y: Double(panel.y) * Double(route.screenScale) / route.screenSize.height)
        #expect(abs(ratio.x - 0.2686) < 0.001)
        #expect(abs(ratio.y - 0.3654) < 0.001)
    }

    @Test("a Resize Mode scene point is normalized against the whole canvas (E14)")
    func resizableRatio() throws {
        let resizable = try #require(try topology("duo-open").display(uniqueID: session.displayUniqueID))
        let routing = RoutingDisplay.resizable(session, resizable)
        #expect(routing.accessibilityDisplayID == 5)
        let route = try #require(try routing.hidRoute())
        #expect(route.digitizerTarget == 5)
        #expect(route.screenSize == CGSize(width: 7680, height: 4320))
        let calibration = try #require(routing.fixedCalibration(sceneSize: CGSize(width: 560, height: 874)))
        #expect(calibration.isIdentity)
        #expect(calibration.uiScreenSize().map { $0.width } == 560)
        let hid = calibration.hidCGPoint(CGPoint(x: 280, y: 435))
        #expect(abs(Double(hid.x) * 3 / 7680 - 0.1094) < 0.0005)
        #expect(abs(Double(hid.y) * 3 / 4320 - 0.3021) < 0.0005)
    }

    @Test("a session whose display CoreDevice did not list cannot be routed")
    func resizableWithoutDisplay() {
        #expect(throws: CLIError.self) { try RoutingDisplay.resizable(session, nil).hidRoute() }
        #expect(RoutingDisplay.resizable(session, nil).accessibilityDisplayID == 0)
    }
}

// MARK: - Touch detection

@Suite("FBSimulatorHIDEvent.containsTouch")
struct HIDEventTouchDetectionTests {
    @Test("touches and two-finger touches, also inside composites, are touch; keys are not")
    func detection() {
        #expect(FBSimulatorHIDEvent.touch(direction: .down, x: 1, y: 1).containsTouch)
        #expect(FBSimulatorHIDEvent.twoFingerTouch(direction: .down, finger1: .zero, finger2: .zero).containsTouch)
        #expect(FBSimulatorHIDEvent.composite([.delay(0.1), .touch(direction: .up, x: 1, y: 1)]).containsTouch)
        #expect(!FBSimulatorHIDEvent.keyboard(direction: .down, keyCode: 4).containsTouch)
        #expect(!FBSimulatorHIDEvent.composite([.keyboard(direction: .down, keyCode: 4), .delay(0.1)]).containsTouch)
        #expect(!FBSimulatorHIDEvent.deviceOrientation(.portrait).containsTouch)
    }
}

// MARK: - Scene placement

/// A display whose app scene is smaller than the display and placed at
/// `offset` (UI points of the display's interface). The probe answers like
/// the hit-test: panel points in, the element's scene frame out.
private final class InsetScreen: @unchecked Sendable {
    let native: NativePortraitSize
    let orientation: DisplayOrientation
    let offset: CGPoint
    let elements: [CGRect]
    /// Elements outside the scene, in display UI points (the status bar).
    let displayElements: [CGRect]
    private let lock = NSLock()
    private var count = 0

    init(native: NativePortraitSize, orientation: DisplayOrientation, offset: CGPoint, elements: [CGRect], displayElements: [CGRect] = []) {
        self.native = native
        self.orientation = orientation
        self.offset = offset
        self.elements = elements
        self.displayElements = displayElements
    }

    var probes: Int { lock.lock(); defer { lock.unlock() }; return count }

    func probe(_ panelPoint: CGPoint) -> [String: Any]? {
        lock.lock(); count += 1; lock.unlock()
        let display = orientation.framebufferToUI(panelPoint, native: native)
        if let decoy = displayElements.first(where: { $0.contains(display) }) {
            return ["role": "AXImage", "frame": ["x": decoy.minX, "y": decoy.minY, "width": decoy.width, "height": decoy.height] as [String: Any]]
        }
        let scene = CGPoint(x: display.x - offset.x, y: display.y - offset.y)
        guard let hit = elements.first(where: { $0.contains(scene) }) else { return nil }
        return ["role": "AXButton", "frame": ["x": hit.minX, "y": hit.minY, "width": hit.width, "height": hit.height] as [String: Any]]
    }
}

/// The Duo cover display and an iOS 27.0 SDK app that keeps out of the
/// 80 pt status bar strip on the hardware's right edge.
private let coverNative = NativePortraitSize(width: 466, height: 678)
private let landscapeCorners = [
    CGRect(x: 16, y: 98, width: 56, height: 56),
    CGRect(x: 606, y: 98, width: 56, height: 56),
    CGRect(x: 16, y: 280, width: 56, height: 56),
    CGRect(x: 606, y: 280, width: 56, height: 56),
]

@Suite("OrientationCalibrator — a scene smaller than its display")
struct SceneOffsetTests {
    @Test("isInsetScene: device sizes and a downscaled panel are not inset; a scene inside the display is")
    func insetDetection() {
        #expect(!OrientationCalibrator.isInsetScene(CGSize(width: 466, height: 678), native: coverNative, uiScale: .identity))
        #expect(!OrientationCalibrator.isInsetScene(CGSize(width: 678, height: 466), native: coverNative, uiScale: .identity))
        #expect(OrientationCalibrator.isInsetScene(CGSize(width: 386, height: 678), native: coverNative, uiScale: .identity))
        #expect(OrientationCalibrator.isInsetScene(CGSize(width: 678, height: 386), native: coverNative, uiScale: .identity))
        // iPhone 12 mini lays out 375x812 over a 360x780 framebuffer.
        let mini = NativePortraitSize(width: 360, height: 780)
        #expect(!OrientationCalibrator.isInsetScene(CGSize(width: 375, height: 812), native: mini, uiScale: UIPointScale(x: 0.96, y: 0.96)))
    }

    @Test("landscape-right on the cover: CoreDevice gives the rotation and probes find the scene 80 pt down (E30)")
    @MainActor
    func coverLandscapeRight() async {
        let screen = InsetScreen(native: coverNative, orientation: .landscapeRight, offset: CGPoint(x: 0, y: 80), elements: landscapeCorners)
        let result = await OrientationCalibrator.calibrate(
            native: coverNative,
            uiScreenSize: (width: 678, height: 386),
            discriminators: landscapeCorners,
            probe: { screen.probe($0) },
            logger: quietLogger,
            authoritative: { .landscapeRight }
        )
        #expect(result.orientation == .landscapeRight)
        #expect(result.sceneOffset == CGPoint(x: 0, y: 80))
        #expect(result.advisory == nil)
        #expect(result.uiScreenSize().map { $0.width } == 678)
        #expect(result.uiScreenSize().map { $0.height } == 386)
        // Every corner maps onto its own element.
        for corner in landscapeCorners {
            let hit = screen.probe(result.probeCGPoint(CGPoint(x: corner.midX, y: corner.midY)))
            #expect(hit != nil)
        }
    }

    @Test("landscape-left on the cover: the scene starts at the display origin")
    @MainActor
    func coverLandscapeLeft() async {
        let screen = InsetScreen(native: coverNative, orientation: .landscapeLeft, offset: .zero, elements: landscapeCorners)
        let result = await OrientationCalibrator.calibrate(
            native: coverNative,
            uiScreenSize: (width: 678, height: 386),
            discriminators: landscapeCorners,
            probe: { screen.probe($0) },
            logger: quietLogger,
            authoritative: { .landscapeLeft }
        )
        #expect(result.orientation == .landscapeLeft)
        #expect(result.sceneOffset == .zero)
        #expect(result.sceneSize == CGSize(width: 678, height: 386))
    }

    @Test("a centred scene (older SDK on the inner display) is found at half the gap")
    @MainActor
    func centredScene() async {
        let inner = NativePortraitSize(width: 669, height: 951)
        let elements = [CGRect(x: 10, y: 10, width: 40, height: 40), CGRect(x: 300, y: 500, width: 40, height: 40)]
        let screen = InsetScreen(native: inner, orientation: .portrait, offset: CGPoint(x: 67.5, y: 69.5), elements: elements)
        let base = OrientationCalibration(orientation: .portrait, native: inner, probesUsed: 0, advisory: nil)
        let result = await OrientationCalibrator.resolveSceneOffset(
            base, sceneSize: CGSize(width: 534, height: 812), discriminators: elements,
            probe: { screen.probe($0) }, logger: quietLogger
        )
        #expect(result.sceneOffset == CGPoint(x: 67.5, y: 69.5))
    }

    @Test("a wide container under the wrong offset does not confirm it")
    @MainActor
    func containerDoesNotConfirmWrongOffset() async {
        // Portrait inner display, scene 669x871 placed 80 pt down. A
        // full-width row sits 80 pt above the probed button, so a probe at
        // offset 0 lands on the row, whose frame covers the button's centre.
        let inner = NativePortraitSize(width: 669, height: 951)
        let button = CGRect(x: 24, y: 120, width: 40, height: 24)
        let row = CGRect(x: 0, y: 40, width: 669, height: 120)
        let screen = InsetScreen(native: inner, orientation: .portrait, offset: CGPoint(x: 0, y: 80), elements: [button, row])
        let base = OrientationCalibration(orientation: .portrait, native: inner, probesUsed: 0, advisory: nil)
        let result = await OrientationCalibrator.resolveSceneOffset(
            base, sceneSize: CGSize(width: 669, height: 871), discriminators: [button],
            probe: { screen.probe($0) }, logger: quietLogger
        )
        #expect(result.sceneOffset == CGPoint(x: 0, y: 80))
    }

    @Test("one coincidental hit inside a probed element does not confirm a wrong offset")
    @MainActor
    func coincidenceNeedsSecondConfirmation() async {
        // LINE (iOS 27.0 SDK) on the portrait inner display: the scene
        // starts 80 pt down. At offset 0 the probe for Help lands on the
        // status bar's Wi-Fi icon, whose frame sits inside Help's rect.
        let inner = NativePortraitSize(width: 669, height: 951)
        let back = CGRect(x: 24, y: 36, width: 40, height: 24)
        let help = CGRect(x: 605, y: 36, width: 40, height: 24)
        let wifi = CGRect(x: 612, y: 41, width: 18, height: 13)
        let screen = InsetScreen(
            native: inner, orientation: .portrait, offset: CGPoint(x: 0, y: 80),
            elements: [back, help], displayElements: [wifi]
        )
        let base = OrientationCalibration(orientation: .portrait, native: inner, probesUsed: 0, advisory: nil)
        let result = await OrientationCalibrator.resolveSceneOffset(
            base, sceneSize: CGSize(width: 669, height: 871), discriminators: [help, back],
            probe: { screen.probe($0) }, logger: quietLogger
        )
        #expect(result.sceneOffset == CGPoint(x: 0, y: 80))
    }

    @Test("an inset scene under rotation maps to the measured panel point (E30, R158-02)")
    func insetMappingUnderRotation() {
        // iOS 27.0 SDK Playground on the Duo cover in landscape-right: the
        // top-trailing corner's centre (634, 126) in scene points was hit
        // live at panel (260, 634), and missed at (340, 634) without the
        // 80 pt offset.
        let calibration = OrientationCalibration(
            orientation: .landscapeRight, native: coverNative, probesUsed: 0, advisory: nil,
            sceneOffset: CGPoint(x: 0, y: 80), sceneSize: CGSize(width: 678, height: 386)
        )
        #expect(calibration.probeCGPoint(CGPoint(x: 634, y: 126)) == CGPoint(x: 260, y: 634))
        #expect(calibration.hidCGPoint(CGPoint(x: 634, y: 126)) == CGPoint(x: 260, y: 634))
        #expect(!calibration.isIdentity)
        let unplaced = OrientationCalibration(orientation: .landscapeRight, native: coverNative, probesUsed: 0, advisory: nil)
        #expect(unplaced.probeCGPoint(CGPoint(x: 634, y: 126)) == CGPoint(x: 340, y: 634))
    }

    @Test("a scene that fills the display costs no probe")
    @MainActor
    func fullScene() async {
        let screen = InsetScreen(native: coverNative, orientation: .portrait, offset: .zero, elements: landscapeCorners)
        let base = OrientationCalibration(orientation: .portrait, native: coverNative, probesUsed: 1, advisory: nil)
        let result = await OrientationCalibrator.resolveSceneOffset(
            base, sceneSize: CGSize(width: 466, height: 678), discriminators: landscapeCorners,
            probe: { screen.probe($0) }, logger: quietLogger
        )
        #expect(screen.probes == 0)
        #expect(result.sceneOffset == .zero)
        #expect(result.sceneSize == nil)
        #expect(result.isIdentity)
    }

    @Test("a scene whose place cannot be confirmed falls back to the origin with an advisory")
    @MainActor
    func unplaceableScene() async {
        let base = OrientationCalibration(orientation: .portrait, native: coverNative, probesUsed: 0, advisory: nil)
        let result = await OrientationCalibrator.resolveSceneOffset(
            base, sceneSize: CGSize(width: 386, height: 678), discriminators: [CGRect(x: 10, y: 10, width: 40, height: 40)],
            probe: { _ in nil }, logger: quietLogger
        )
        #expect(result.sceneOffset == .zero)
        #expect(result.advisory?.kind == .orientationCalibrationFallback)
    }

    @Test("an ambiguous full-size calibration takes CoreDevice's rotation instead of guessing")
    @MainActor
    func authoritativeOnAmbiguity() async {
        let result = await OrientationCalibrator.calibrate(
            native: coverNative,
            uiScreenSize: (width: 678, height: 466),
            discriminators: [],
            probe: { _ in nil },
            logger: quietLogger,
            authoritative: { .landscapeRight }
        )
        #expect(result.orientation == .landscapeRight)
        #expect(result.advisory == nil)
    }
}
