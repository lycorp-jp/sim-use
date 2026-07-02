// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import Testing

private func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> AccessibilityElement.Frame {
    let dict: [String: Any] = ["x": x, "y": y, "width": w, "height": h]
    // Frame is Decodable-only; build it through JSON like the AX pipeline does.
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(AccessibilityElement.Frame.self, from: data)
}

@Suite("FullScreenTapAdvisory")
struct FullScreenTapAdvisoryTests {
    private let screen = frame(0, 0, 400, 800)

    @Test("warns when the matched element covers the whole screen")
    func warnsOnFullScreen() {
        let msg = FullScreenTapAdvisory.message(matched: frame(0, 0, 400, 800), screen: screen, query: "노브")
        #expect(msg != nil)
        #expect(msg?.contains("100%") == true)
        #expect(msg?.contains("노브") == true)
    }

    @Test("warns at the 90% threshold")
    func warnsAtThreshold() {
        // 400x720 = 288000 / 320000 = 90%.
        #expect(FullScreenTapAdvisory.message(matched: frame(0, 0, 400, 720), screen: screen, query: "x") != nil)
    }

    @Test("stays silent for a normal-sized control")
    func silentForSmallElement() {
        #expect(FullScreenTapAdvisory.message(matched: frame(10, 700, 80, 40), screen: screen, query: "x") == nil)
    }

    @Test("stays silent when a frame is missing or degenerate")
    func silentForDegenerate() {
        #expect(FullScreenTapAdvisory.message(matched: frame(0, 0, 400, 800), screen: nil, query: "x") == nil)
        #expect(FullScreenTapAdvisory.message(matched: frame(0, 0, 0, 0), screen: screen, query: "x") == nil)
    }
}
