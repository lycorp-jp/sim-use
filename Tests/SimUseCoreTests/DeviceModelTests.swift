// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import XCTest

/// Guards the `Device` model contract: `isUsable` must match each
/// platform's "right now reachable" semantic, and Codable shape stays
/// the wire format the Viewer + scripts consume.
final class DeviceModelTests: XCTestCase {

    // MARK: - isUsable

    func testIOSBootedIsUsable() {
        let d = Device(udid: "X", name: "iPhone", platform: .ios, state: "Booted", runtime: "iOS 18.6")
        XCTAssertTrue(d.isUsable)
    }

    func testIOSShutdownIsNotUsable() {
        let d = Device(udid: "X", name: "iPhone", platform: .ios, state: "Shutdown", runtime: "iOS 18.6")
        XCTAssertFalse(d.isUsable)
    }

    func testIOSTransitionalStatesAreNotUsable() {
        // sim-use can't drive HID against a half-booted sim, so be strict.
        for state in ["Booting", "Shutting Down", "Creating"] {
            let d = Device(udid: "X", name: "iPhone", platform: .ios, state: state, runtime: "iOS 18.6")
            XCTAssertFalse(d.isUsable, "iOS state \(state) should not be usable")
        }
    }

    func testAndroidDeviceStateIsUsable() {
        let d = Device(udid: "emulator-5554", name: "Pixel", platform: .android, state: "device", runtime: "Android")
        XCTAssertTrue(d.isUsable)
    }

    func testAndroidOfflineAndUnauthorisedAreNotUsable() {
        for state in ["offline", "unauthorized", "no device"] {
            let d = Device(udid: "emulator-5554", name: "Pixel", platform: .android, state: state, runtime: "Android")
            XCTAssertFalse(d.isUsable, "Android state '\(state)' should not be usable")
        }
    }

    // MARK: - JSON encoding (wire format)

    func testJSONShapeMatchesWireExpectation() throws {
        let d = Device(udid: "u", name: "n", platform: .ios, state: "Booted", runtime: "iOS 18.6")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(data: try encoder.encode(d), encoding: .utf8)
        // Field order is sorted (sortedKeys); platform is the rawValue
        // string, not an integer. `deviceId` is the new cross-platform
        // synonym for `udid`; both keys are emitted with identical
        // values during the deprecation window so existing Viewer / jq
        // consumers keep working. Drop `udid` from this assertion in
        // Phase 2 once it is removed from the wire.
        XCTAssertEqual(json, #"{"deviceId":"u","name":"n","platform":"ios","runtime":"iOS 18.6","state":"Booted","udid":"u"}"#)
    }

    func testJSONAcceptsDeviceIdOnly() throws {
        // Legacy consumers shipped only `udid`. Verify the new decode
        // path accepts payloads that have only `deviceId` (the Phase 2
        // shape) so the wire migration can complete without breaking
        // the in-tree decoder.
        let payload = #"{"deviceId":"abc","name":"x","platform":"ios","state":"Booted"}"#
        let d = try JSONDecoder().decode(Device.self, from: Data(payload.utf8))
        XCTAssertEqual(d.udid, "abc")
    }

    func testJSONAcceptsUDIDOnly() throws {
        // Pre-dual-key payloads with only `udid` must still decode.
        let payload = #"{"udid":"abc","name":"x","platform":"ios","state":"Booted"}"#
        let d = try JSONDecoder().decode(Device.self, from: Data(payload.utf8))
        XCTAssertEqual(d.udid, "abc")
    }

    func testJSONRejectsPayloadMissingBothKeys() throws {
        let payload = #"{"name":"x","platform":"ios","state":"Booted"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Device.self, from: Data(payload.utf8)))
    }

    func testJSONRoundTrip() throws {
        let original = Device(udid: "emulator-5554", name: "Pixel", platform: .android, state: "device", runtime: "Android")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Device.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testNilRuntimeIsOmittedFromJSON() throws {
        // Per Swift's default JSONEncoder behaviour, nil optional fields
        // are omitted entirely (not encoded as JSON null). Consumers
        // (the Viewer server, jq scripts) must treat a missing `runtime`
        // and an explicit null identically — both mean "platform has no
        // runtime to report".
        let d = Device(udid: "u", name: "n", platform: .android, state: "device", runtime: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(d), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("runtime"),
                       "runtime: nil should be omitted from JSON, got: \(json)")
        // Round-trips back to nil regardless.
        let decoded = try JSONDecoder().decode(Device.self, from: Data(json.utf8))
        XCTAssertNil(decoded.runtime)
    }
}