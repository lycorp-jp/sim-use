// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend

/// Diagnostics for the "first call against an un-bootstrapped Android
/// device returns an opaque `Bridge transport error: The network
/// connection was lost.`" failure mode. Two layers are covered:
///
///  1. `BridgeError.hint` — the residual safety net for an installed
///     bridge that was never fully bootstrapped (a11y off, server off,
///     stale forward). Pure, no I/O.
///  2. `BridgeClient.connectionFailure` — the dominant case (APK never
///     installed) gets mapped to `.bridgeNotInstalled` via a one-shot
///     `pm list packages` probe. Driven with a script-backed `Adb`.
final class BridgeTransportDiagnosticsTests: XCTestCase {

    // MARK: - Hint logic (pure)

    func testTransportHintNudgesTowardInitWhenSerialKnownAndConnectionFailed() {
        let err = BridgeError.transport(
            underlying: "The network connection was lost.",
            serial: "emulator-5554"
        )
        let hint = err.hint
        XCTAssertNotNil(hint, "a connection-level transport failure with a known serial must carry a hint")
        XCTAssertTrue(hint!.contains("sim-use android init --device emulator-5554"), hint!)
        XCTAssertTrue(hint!.contains("daemon will not help"), hint!)
    }

    func testTransportHintMatchesCommonBootstrapFailureStrings() {
        for underlying in [
            "The network connection was lost.",
            "Could not connect to the server.",
            "Connection refused",
            "Non-HTTP response from bridge",
        ] {
            let err = BridgeError.transport(underlying: underlying, serial: "X")
            XCTAssertNotNil(err.hint, "expected hint for underlying: \(underlying)")
        }
    }

    func testTransportHintSuppressedWithoutSerial() {
        // `serial: nil` marks failures not tied to a reachable device
        // (URL build, missing APK during init) — those carry their own
        // message and must not get a misleading "go re-init" nudge.
        let err = BridgeError.transport(underlying: "The network connection was lost.", serial: nil)
        XCTAssertNil(err.hint)
    }

    func testTransportHintSuppressedForNonBootstrapFailure() {
        // A serial is known but the failure isn't a connection-level
        // bootstrap symptom — don't claim re-init fixes it.
        let err = BridgeError.transport(underlying: "some unrelated error", serial: "emulator-5554")
        XCTAssertNil(err.hint)
    }

    func testBridgeNotInstalledCopyUsesDeviceFlag() {
        let err = BridgeError.bridgeNotInstalled(serial: "emulator-5554")
        let msg = err.localizedDescription
        XCTAssertTrue(msg.contains("sim-use android init --device emulator-5554"), msg)
    }

    // MARK: - connectionFailure mapping (script-backed adb)

    /// APK absent → `pm list packages` returns nothing → map to the
    /// actionable `.bridgeNotInstalled` instead of the opaque transport
    /// error.
    func testConnectionFailureMapsMissingApkToBridgeNotInstalled() throws {
        let adb = try Self.scriptedAdb(stdout: "")
        let client = BridgeClient(adb: adb, serial: "emulator-5554")
        let mapped = client.connectionFailure(underlying: Self.networkConnectionLost)
        guard case BridgeError.bridgeNotInstalled(let serial) = mapped else {
            XCTFail("expected .bridgeNotInstalled; got \(mapped)")
            return
        }
        XCTAssertEqual(serial, "emulator-5554")
    }

    /// APK present but the connection still failed → keep the transport
    /// error, now tagged with the serial so the hint can fire.
    func testConnectionFailureKeepsTransportWhenApkPresent() throws {
        let adb = try Self.scriptedAdb(stdout: "package:\(BridgeClient.bridgePackageName)\n")
        let client = BridgeClient(adb: adb, serial: "emulator-5554")
        let mapped = client.connectionFailure(underlying: Self.networkConnectionLost)
        guard case BridgeError.transport(_, let serial) = mapped else {
            XCTFail("expected .transport; got \(mapped)")
            return
        }
        XCTAssertEqual(serial, "emulator-5554")
        XCTAssertNotNil(mapped.hint, "transport with a serial + connection-loss underlying should hint")
    }

    // MARK: - Helpers

    /// An `Adb` whose binary is a throwaway shell script that ignores
    /// its arguments and prints `stdout`, exit 0. Lets us pin the
    /// `pm list packages` probe output without a device.
    private static func scriptedAdb(stdout: String) throws -> Adb {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake-adb")
        let body = "#!/bin/sh\nprintf '%s' \(shellQuote(stdout))\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return Adb(binaryPath: script.path, defaultTimeout: 5)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Mirrors what `URLSession` actually throws when the bridge socket
    /// drops: `NSURLErrorDomain` -1005 with a populated localized
    /// description. A bare `URLError(.networkConnectionLost)` has a
    /// generic localized string, so we construct the realistic shape.
    private static let networkConnectionLost = NSError(
        domain: NSURLErrorDomain,
        code: NSURLErrorNetworkConnectionLost,
        userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]
    )
}