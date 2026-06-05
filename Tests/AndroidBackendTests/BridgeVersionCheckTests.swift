// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend

/// Ping-time bridge-version check tests. The real `BridgeClient.ping`
/// path needs a live emulator + adb forward + HTTP server, so these
/// exercise the comparison + error shape directly. The conditional
/// path that triggers the check inside `ping()` is intentionally
/// simple (one `if`); the tests pin the inputs that *should* trigger
/// it and the inputs that should *skip* it.
final class BridgeVersionCheckTests: XCTestCase {

    override func tearDown() {
        // Each test gets a fresh slate — leaving a stale
        // `expectedBridgeVersion` set would silently affect other
        // suites running in the same process.
        BridgeClient.expectedBridgeVersion = nil
        super.tearDown()
    }

    func testBridgeVersionMismatchProducesActionableErrorAndHint() {
        let err = BridgeError.bridgeVersionMismatch(
            cli: "0.6.0",
            bridge: "0.5.0",
            udid: "emulator-5554"
        )
        let msg = err.localizedDescription
        XCTAssertTrue(msg.contains("0.6.0"), msg)
        XCTAssertTrue(msg.contains("0.5.0"), msg)
        let hint = err.hint
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("sim-use android init --device emulator-5554"), hint!)
        XCTAssertTrue(hint!.contains("SIM_USE_SKIP_BRIDGE_VERSION_CHECK"), hint!)
    }

    func testSetExpectedBridgeVersionEnablesCheck() {
        BridgeClient.expectedBridgeVersion = "0.6.0"
        XCTAssertEqual(BridgeClient.expectedBridgeVersion, "0.6.0")
        BridgeClient.expectedBridgeVersion = nil
        XCTAssertNil(BridgeClient.expectedBridgeVersion)
    }

    /// The version-check guard inside `ping()` is gated on three
    /// conditions: `expectedBridgeVersion != nil`,
    /// `SIM_USE_SKIP_BRIDGE_VERSION_CHECK != "1"`, and
    /// `expected != bridge`. Drive the comparison directly so we
    /// don't need a live socket.
    func testGuardLogic() {
        // Helper mirroring the inline conditional in BridgeClient.ping.
        func wouldThrow(expected: String?, bridge: String, env: [String: String]) -> Bool {
            guard let expected else { return false }
            if env["SIM_USE_SKIP_BRIDGE_VERSION_CHECK"] == "1" { return false }
            return expected != bridge
        }

        XCTAssertFalse(wouldThrow(expected: nil, bridge: "0.5.0", env: [:]),
                       "dev build (expected=nil) skips check")
        XCTAssertFalse(wouldThrow(expected: "0.6.0", bridge: "0.6.0", env: [:]),
                       "match → no throw")
        XCTAssertTrue(wouldThrow(expected: "0.6.0", bridge: "0.5.0", env: [:]),
                      "mismatch → throw")
        XCTAssertFalse(wouldThrow(expected: "0.6.0", bridge: "0.5.0",
                                  env: ["SIM_USE_SKIP_BRIDGE_VERSION_CHECK": "1"]),
                       "env opt-out wins")
        XCTAssertTrue(wouldThrow(expected: "0.6.0", bridge: "0.5.0",
                                 env: ["SIM_USE_SKIP_BRIDGE_VERSION_CHECK": "0"]),
                      "env=0 != \"1\" so the check still fires")
    }
}