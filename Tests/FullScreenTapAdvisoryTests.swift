// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

private func advisoryFrame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> AccessibilityElement.Frame {
    let dict: [String: Any] = ["x": x, "y": y, "width": w, "height": h]
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(AccessibilityElement.Frame.self, from: data)
}

private func advisoryElement(
    type: String = "Application",
    label: String = "App",
    frame: AccessibilityElement.Frame,
    children: [[String: Any]] = []
) throws -> AccessibilityElement {
    var dict: [String: Any] = [
        "type": type,
        "AXLabel": label,
        "frame": ["x": frame.x, "y": frame.y, "width": frame.width, "height": frame.height],
    ]
    if !children.isEmpty {
        dict["children"] = children
    }
    let data = try JSONSerialization.data(withJSONObject: dict)
    return try JSONDecoder().decode(AccessibilityElement.self, from: data)
}

@Suite("FullScreenTapAdvisory")
struct FullScreenTapAdvisoryTests {
    private let screen = advisoryFrame(0, 0, 400, 800)

    @Test("warns when matched element covers the display")
    func warnsOnFullScreenMatch() {
        let message = FullScreenTapAdvisory.message(
            matched: advisoryFrame(0, 0, 400, 800),
            screen: screen,
            query: "Flutter wrapper"
        )
        #expect(message?.contains("100%") == true)
        #expect(message?.contains("Flutter wrapper") == true)
    }

    @Test("warns at the 90% threshold")
    func warnsAtThreshold() {
        let message = FullScreenTapAdvisory.message(
            matched: advisoryFrame(0, 0, 400, 720),
            screen: screen,
            query: "x"
        )
        #expect(message != nil)
    }

    @Test("stays silent for normal controls")
    func silentForNormalControl() {
        let message = FullScreenTapAdvisory.message(
            matched: advisoryFrame(10, 700, 80, 40),
            screen: screen,
            query: "x"
        )
        #expect(message == nil)
    }

    @Test("uses the largest root frame as display denominator")
    func usesLargestRootFrame() throws {
        let keyboardRoot = try advisoryElement(
            label: "Keyboard",
            frame: advisoryFrame(0, 500, 400, 300)
        )
        let appRoot = try advisoryElement(
            label: "App",
            frame: screen,
            children: [[
                "type": "Button",
                "AXLabel": "Submit",
                "frame": ["x": 0, "y": 0, "width": 400, "height": 300],
            ]]
        )

        let target = try AccessibilityTargetResolver.resolveTarget(
            roots: [keyboardRoot, appRoot],
            query: .label("Submit")
        )

        #expect(target.x == 200)
        #expect(target.y == 150)
        #expect(target.advisory == nil)
    }

    @Test("prefers the Application root over a larger non-Application root")
    func prefersApplicationRootOverLargerWindow() throws {
        // A scroll-canvas window taller than the display must not
        // deflate the coverage fraction: the wrapper is 97.5% of the
        // Application root but only 26% of the canvas window.
        let canvasRoot = try advisoryElement(
            type: "Window",
            label: "Canvas",
            frame: advisoryFrame(0, 0, 400, 3000)
        )
        let appRoot = try advisoryElement(
            label: "App",
            frame: screen,
            children: [[
                "type": "Other",
                "AXLabel": "Full Screen Wrapper",
                "frame": ["x": 0, "y": 10, "width": 400, "height": 780],
            ]]
        )

        let target = try AccessibilityTargetResolver.resolveTarget(
            roots: [canvasRoot, appRoot],
            query: .label("Full Screen Wrapper")
        )

        #expect(target.advisory != nil)
    }

    @Test("display frame falls back to the largest root when no Application root has a frame")
    func fallsBackToLargestRootWithoutApplication() throws {
        let smallWindow = try advisoryElement(type: "Window", label: "Overlay", frame: advisoryFrame(0, 0, 100, 100))
        let bigWindow = try advisoryElement(type: "Window", label: "Main", frame: advisoryFrame(0, 0, 400, 800))
        let frame = try #require(AXDisplayFrame.frame(in: [smallWindow, bigWindow]))
        #expect(frame.width == 400)
        #expect(frame.height == 800)
    }

    @Test("tap execution result keeps advisory out of data payload")
    func tapResultDoesNotEncodeAdvisoryInData() throws {
        let result = IOSSimTapCommand.ExecutionResult(
            x: 10,
            y: 20,
            advisory: CommandAdvisory(kind: .fullScreenTapTarget, message: "check target")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = String(data: try encoder.encode(result), encoding: .utf8)
        #expect(text == #"{"x":10,"y":20}"#)
    }
}
