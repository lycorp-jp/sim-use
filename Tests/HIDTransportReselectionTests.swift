// SPDX-License-Identifier: Apache-2.0
import FBSimulatorControl
@testable import iOSSimBackend
import Testing

// With Device Hub closed a simulator boots without dtuhidd, so the HID
// connection auto-selects the legacy Indigo transport. sim-use's own fold
// and rotate start dtuhidd on demand (its XPC service), and an active
// dtuhidd suppresses the legacy keyboard service: a cached Indigo
// connection then drops typed text silently. Touch input routed to a
// display other than the main one needs DTUHID too
// (docs/ai/010-display-routing, S6).

@Suite("HID transport re-selection when dtuhidd appears")
struct HIDTransportReselectionTests {
    @Test("an auto-selected Indigo connection is replaced once dtuhidd runs")
    func indigoReplaced() {
        #expect(HIDInteractor.transportOutdated(selected: .indigo, forced: false, dtuhiddPresent: true))
    }

    @Test("Indigo stays while dtuhidd is absent; DTUHID stays always", arguments: [
        (FBSimulatorHIDTransportType.indigo, false),
        (.dtuhid, true),
        (.dtuhid, false),
    ])
    func kept(selected: FBSimulatorHIDTransportType, present: Bool) {
        #expect(!HIDInteractor.transportOutdated(selected: selected, forced: false, dtuhiddPresent: present))
    }

    @Test("a forced transport (SIM_USE_HID_TRANSPORT) is never replaced")
    func forcedKept() {
        #expect(!HIDInteractor.transportOutdated(selected: .indigo, forced: true, dtuhiddPresent: true))
    }

    @Test("an unknown selection or presence keeps the connection")
    func unknownKept() {
        #expect(!HIDInteractor.transportOutdated(selected: nil, forced: false, dtuhiddPresent: true))
        #expect(!HIDInteractor.transportOutdated(selected: .indigo, forced: false, dtuhiddPresent: nil))
    }

    @Test("the selection follows dtuhidd presence, or the override")
    func selection() {
        #expect(HIDInteractor.selectedTransport(override: nil, dtuhiddPresent: true) == .dtuhid)
        #expect(HIDInteractor.selectedTransport(override: nil, dtuhiddPresent: false) == .indigo)
        #expect(HIDInteractor.selectedTransport(override: nil, dtuhiddPresent: nil) == nil)
        #expect(HIDInteractor.selectedTransport(override: .indigo, dtuhiddPresent: true) == .indigo)
    }

    @Test("routed touch input needs DTUHID")
    func routeNeedsDTUHID() {
        let route = FBSimulatorHIDDisplayRoute(digitizerTarget: 3, screenSize: CGSize(width: 2007, height: 2853), screenScale: 3)
        #expect(HIDInteractor.routeNeedsDTUHID(route: route, transport: .indigo))
        #expect(!HIDInteractor.routeNeedsDTUHID(route: route, transport: .dtuhid))
        #expect(!HIDInteractor.routeNeedsDTUHID(route: nil, transport: .indigo))
    }
}
