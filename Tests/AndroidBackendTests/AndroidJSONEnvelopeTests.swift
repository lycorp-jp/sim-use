// SPDX-License-Identifier: Apache-2.0
import XCTest
import SimUseCore
@testable import AndroidBackend

/// Snapshot tests for the `--json` envelope shape on the Android-side
/// verbs that emit JSON (`keyboard-state`, `describe-ui`, `devices`).
///
/// The verbs themselves require a live bridge / adb, so these tests
/// take the verb's wire `Payload` type and route it through
/// `JSONEnvelopeWriter` directly — same code path the verb's `run()`
/// uses. That's enough to pin the cross-surface contract: an agent
/// switching between `sim-use keyboard-state` and
/// `sim-use android keyboard-state` must see one schema, and these
/// snapshots are the line of defense against silent drift.
final class AndroidJSONEnvelopeTests: XCTestCase {
    func testKeyboardStatePayloadEnvelopeShape() throws {
        let payload = AndroidKeyboardStateCommand.ExecutionResult(
            visible: true,
            imePackage: "com.example.ime"
        )
        let bytes = try JSONEnvelopeWriter.encodeSuccess(payload)
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertEqual(
            json,
            #"{"data":{"imePackage":"com.example.ime","platform":"android","visible":true},"ok":true}"#
        )
    }

    func testKeyboardStatePayloadOmitsNilIMEPackage() throws {
        // Swift's synthesised Encodable uses `encodeIfPresent` for
        // Optional, so a nil `imePackage` drops out of the JSON.
        // This matches the tagged-union shape iOS-side
        // `ExecutionResult` produces — the agent reads "absent key
        // means N/A" consistently across both surfaces.
        let payload = AndroidKeyboardStateCommand.ExecutionResult(
            visible: false,
            imePackage: nil
        )
        let bytes = try JSONEnvelopeWriter.encodeSuccess(payload)
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertEqual(
            json,
            #"{"data":{"platform":"android","visible":false},"ok":true}"#
        )
    }

    func testTapPayloadEnvelopeShape() throws {
        // Mirrors the iOS-side `IOSSimTapCommand.ExecutionResult` so
        // `sim-use tap --json` and `sim-use android tap --json`
        // produce byte-identical envelopes for the same coordinates.
        let payload = AndroidTapCommand.ExecutionResult(x: 100.0, y: 200.5, description: "test")
        let bytes = try JSONEnvelopeWriter.encodeSuccess(payload)
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertEqual(json, #"{"data":{"x":100,"y":200.5},"ok":true}"#)
    }

    func testEmptyExecutionResultEnvelopeShape() throws {
        // The default for swipe / touch / type / paste / button /
        // gesture — a bare `{ok: true, data: {}}` envelope. Each
        // Android verb declares its own `ExecutionResult: Codable`
        // with no fields; pin AndroidSwipeCommand's as canonical so
        // the protocol-default path can never silently drift.
        let bytes = try JSONEnvelopeWriter.encodeSuccess(AndroidSwipeCommand.ExecutionResult())
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertEqual(json, #"{"data":{},"ok":true}"#)
    }

    func testScreenshotPayloadEnvelopeShape() throws {
        let payload = AndroidScreenshotCommand.ExecutionResult(path: "/tmp/screenshot.png")
        let bytes = try JSONEnvelopeWriter.encodeSuccess(payload)
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertEqual(json, #"{"data":{"path":"/tmp/screenshot.png"},"ok":true}"#)
    }

    func testPingPayloadEnvelopeShape() throws {
        let payload = AndroidPingCommand.ExecutionResult(bridgeVersion: "0.6.0", protocolVersion: 3)
        let bytes = try JSONEnvelopeWriter.encodeSuccess(payload)
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertEqual(json, #"{"data":{"bridgeVersion":"0.6.0","protocolVersion":3},"ok":true}"#)
    }

    func testInitPayloadEnvelopeShape() throws {
        let payload = AndroidInitCommand.ExecutionResult(
            serial: "emulator-5554",
            bridgeVersion: "0.6.0",
            protocolVersion: 3,
            authTokenInstalled: true,
            portForward: 8765
        )
        let bytes = try JSONEnvelopeWriter.encodeSuccess(payload)
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertEqual(
            json,
            #"{"data":{"authTokenInstalled":true,"bridgeVersion":"0.6.0","portForward":8765,"protocolVersion":3,"serial":"emulator-5554"},"ok":true}"#
        )
    }

    func testDevicesPayloadEnvelopeShape() throws {
        let devices: [Device] = [
            Device(
                udid: "emulator-5554",
                name: "Pixel_7_API_35",
                platform: .android,
                state: Device.State.androidOnline,
                runtime: nil
            )
        ]
        let payload = AndroidDevicesCommand.ExecutionResult(devices: devices, adbRows: [])
        let bytes = try JSONEnvelopeWriter.encodeSuccess(payload)
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        // Cross-platform `sim-use devices --json` emits exactly this
        // shape on Android UDIDs.
        XCTAssertTrue(json.hasPrefix(#"{"data":{"devices":["#), json)
        XCTAssertTrue(json.hasSuffix(#"]},"ok":true}"#), json)
        XCTAssertTrue(json.contains(#""deviceId":"emulator-5554""#), json)
        XCTAssertFalse(json.contains(#""udid""#), "legacy `udid` key must not be emitted: \(json)")
        XCTAssertTrue(json.contains(#""platform":"android""#), json)
    }
}