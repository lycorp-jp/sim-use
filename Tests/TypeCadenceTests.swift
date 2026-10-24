// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import FBSimulatorControl
import Foundation
import Testing

@Suite("Type cadence")
@MainActor
struct TypeCadenceTests {
    @Test("Every key event is sent without its own stabilization sleep, then one sleep follows")
    func oneSleepPerText() async throws {
        let events = try TextToHIDEvents.convertTextToHIDEvents("0xA1")
        var log: [String] = []
        try await IOSSimTypeCommand.send(events, keyDelayMs: 0, perform: { _ in
            log.append("event")
        }, pause: { _ in log.append("pause") }, stabilize: { log.append("sleep") })
        #expect(events.count == 10)  // 0, x, 1 = 2 events each; A = shift + key = 4
        #expect(log == Array(repeating: "event", count: events.count) + ["sleep"])
    }

    @Test("A key delay pauses after every event, then the single sleep follows")
    func keyDelay() async throws {
        let events = try TextToHIDEvents.convertTextToHIDEvents("ab")
        var log: [String] = []
        try await IOSSimTypeCommand.send(events, keyDelayMs: 25, perform: { _ in
            log.append("event")
        }, pause: { log.append("pause \($0)") }, stabilize: { log.append("sleep") })
        #expect(log == Array(repeating: ["event", "pause 25"], count: events.count).flatMap { $0 } + ["sleep"])
    }

    @Test("Empty text still ends with the single sleep only")
    func emptyText() async throws {
        var log: [String] = []
        try await IOSSimTypeCommand.send([], keyDelayMs: 0, perform: { _ in log.append("event") },
                                         pause: { _ in log.append("pause") }, stabilize: { log.append("sleep") })
        #expect(log == ["sleep"])
    }
}
