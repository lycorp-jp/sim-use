// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend

final class AdbParserTests: XCTestCase {

    func testParsesSingleEmulator() {
        let output = """
        List of devices attached
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 transport_id:1

        """
        let devices = Adb.parseDevices(output)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].serial, "emulator-5554")
        XCTAssertEqual(devices[0].state, "device")
        XCTAssertEqual(devices[0].model, "sdk_gphone64_arm64")
        XCTAssertEqual(devices[0].product, "sdk_gphone64_arm64")
        XCTAssertTrue(devices[0].isOnline)
        XCTAssertTrue(devices[0].isEmulator)
    }

    func testParsesMultipleDevicesAndStates() {
        let output = """
        List of devices attached
        emulator-5554  device  model:Pixel_5
        R5CT1ABCD12   unauthorized
        emulator-5556  offline
        """
        let devices = Adb.parseDevices(output)
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices[0].serial, "emulator-5554")
        XCTAssertTrue(devices[0].isOnline)
        XCTAssertEqual(devices[1].serial, "R5CT1ABCD12")
        XCTAssertFalse(devices[1].isOnline)
        XCTAssertEqual(devices[2].state, "offline")
    }

    func testEmptyOutputProducesNoDevices() {
        XCTAssertEqual(Adb.parseDevices(""), [])
        XCTAssertEqual(Adb.parseDevices("List of devices attached\n"), [])
    }

    // MARK: - parseForwardPort

    /// Bare port (the common case): `adb forward tcp:0 tcp:8080`
    /// prints the dynamically-assigned local port and nothing else.
    func testParseForwardPortBareNumber() {
        XCTAssertEqual(Adb.parseForwardPort("12345"), 12345)
        XCTAssertEqual(Adb.parseForwardPort("  6789  \n"), 6789)
    }

    /// Some adb builds emit a status line before the port when
    /// they reuse an existing forward (e.g. `Killed running
    /// daemon\n12345`). `Int(trimmed)` of the whole stdout fails
    /// in that case; pick the last non-empty line.
    func testParseForwardPortWithPrefixLines() {
        let output = "Killed running adb server\n12345\n"
        XCTAssertEqual(Adb.parseForwardPort(output), 12345)
    }

    /// Multi-line prefix shouldn't trip the parser — the port is
    /// always the last numeric line.
    func testParseForwardPortIgnoresEmptyTrailingLines() {
        let output = "warning: some message\n\n4711\n\n"
        XCTAssertEqual(Adb.parseForwardPort(output), 4711)
    }

    func testParseForwardPortInvalidReturnsNil() {
        XCTAssertNil(Adb.parseForwardPort("not a number"))
        XCTAssertNil(Adb.parseForwardPort(""))
        XCTAssertNil(Adb.parseForwardPort("0"))           // 0 is not a valid port
        XCTAssertNil(Adb.parseForwardPort("-1234"))
    }
}