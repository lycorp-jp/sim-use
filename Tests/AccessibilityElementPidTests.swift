// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import Foundation
import Testing

@Suite("AccessibilityElement — pid decoding")
struct AccessibilityElementPidTests {

    @Test("Decodes pid when present")
    func decodesPidPresent() throws {
        let json = #"{"type":"Application","pid":12345,"frame":{"x":0,"y":0,"width":390,"height":844}}"#
        let element = try JSONDecoder().decode(AccessibilityElement.self, from: Data(json.utf8))
        #expect(element.pid == 12345)
        #expect(element.type == "Application")
    }

    @Test("pid is nil when absent")
    func pidNilWhenAbsent() throws {
        let json = #"{"type":"Button","AXLabel":"Tap me"}"#
        let element = try JSONDecoder().decode(AccessibilityElement.self, from: Data(json.utf8))
        #expect(element.pid == nil)
    }

    @Test("Recursively keeps pid on children")
    func pidOnChildren() throws {
        let json = """
        {"type":"Application","pid":7777,
         "children":[{"type":"Button","pid":7777,"AXLabel":"OK"}]}
        """
        let element = try JSONDecoder().decode(AccessibilityElement.self, from: Data(json.utf8))
        #expect(element.pid == 7777)
        #expect(element.children?.first?.pid == 7777)
    }
}