// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

// Video capture of the display that hosts the app
// (docs/ai/010-display-routing, S5): the framebuffer port a capture reads,
// named by its unrotated pixel size, and the part of it that shows the app.

private func topology(_ name: String) throws -> SimulatorDisplayTopology {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/display-topology/\(name)", withExtension: "json"))
    let output = DevicectlQueryOutput(terminationStatus: 0, stdout: try Data(contentsOf: url), stderr: Data())
    return try #require(SimulatorDisplayTopologyProbe.classify(output).topology)
}

@Suite("RoutingDisplay — capture source")
struct CaptureSourceTests {
    @Test("the main display keeps the historical capture")
    func main() throws {
        #expect(try RoutingDisplay.main.captureSource() == nil)
    }

    @Test("the Duo inner display: its whole 2007x2853 panel")
    func inner() throws {
        let inner = try #require(try topology("duo-open").activeIntegrated)
        let source = try #require(try RoutingDisplay.secondary(inner).captureSource())
        #expect(source.pixelWidth == 2007 && source.pixelHeight == 2853)
        #expect(source.crop == nil)
        #expect(source.displayName == "LCD-1")
    }

    @Test("a Resize Mode session: the canvas, cut to the scene at its origin")
    func resizable() throws {
        let topology = try topology("iphone17")
        let canvas = try #require(topology.displays.first { $0.name == "Resizable" })
        let session = ResizableAppSession(displayUniqueID: canvas.uniqueID, displayName: "Resizable", preferredWidth: 560, preferredHeight: 874)
        let source = try #require(try RoutingDisplay.resizable(session, canvas).captureSource())
        #expect(source.pixelWidth == 7680 && source.pixelHeight == 4320)
        // 560x874 pt at 3x, measured live as a 1680x2622 `simctl recordVideo`.
        #expect(source.crop == CGRect(x: 0, y: 0, width: 1680, height: 2622))
    }

    @Test("a session whose display CoreDevice did not list cannot be captured")
    func resizableWithoutDisplay() {
        let session = ResizableAppSession(displayUniqueID: "X", displayName: "Resizable", preferredWidth: 560, preferredHeight: 874)
        #expect(throws: (any Error).self) { try RoutingDisplay.resizable(session, nil).captureSource() }
    }
}
