// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend

final class BridgeSessionStoreTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sim-use-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempHome.path) {
            try FileManager.default.removeItem(at: tempHome)
        }
    }

    // MARK: - File permissions

    /// The persisted session file holds the bearer token used to talk
    /// to the on-device HTTP bridge. Default `Data.write` inherits
    /// umask — typically 0o644 = world-readable, so any other local
    /// user on the same Mac could harvest the token. The store must
    /// chmod the file to 0o600 explicitly.
    func testWriteCreatesFileWith0600Permissions() throws {
        let session = BridgeSession(token: "secret", localPort: 12345, remotePort: 8080)
        BridgeSessionStore.write(session, udid: "emulator-5554", home: tempHome)

        let url = BridgeSessionStore.file(for: "emulator-5554", home: tempHome)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(
            mode & 0o777,
            0o600,
            "Bridge session file holds the bearer token; must be 0o600 (got 0o\(String(mode & 0o777, radix: 8))"
        )
    }

    // MARK: - UDID validation (path-traversal defence)

    /// A udid like `../escapee` would resolve to `~/escapee/bridge.json`
    /// outside the `~/.sim-use/` tree. The store rejects it silently
    /// (consistent with the existing "best-effort" contract that
    /// already swallows JSON encode failures): no write happens and
    /// the file is not created anywhere reachable.
    func testWriteRejectsTraversalUdid() {
        let session = BridgeSession(token: "secret", localPort: 1, remotePort: 8080)
        BridgeSessionStore.write(session, udid: "..", home: tempHome)
        BridgeSessionStore.write(session, udid: "../escape", home: tempHome)

        // Nothing should have been written under tempHome — neither
        // the bare `..` nor `../escape` paths should produce files.
        let escapedPath = tempHome.appendingPathComponent("../escape/bridge.json").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedPath))
        let dotDotPath = tempHome.appendingPathComponent("../bridge.json").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: dotDotPath))
    }

    func testWriteRejectsSlashInUdid() {
        let session = BridgeSession(token: "secret", localPort: 1, remotePort: 8080)
        BridgeSessionStore.write(session, udid: "a/b", home: tempHome)
        let path = BridgeSessionStore.file(for: "a/b", home: tempHome).path
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testWriteRejectsEmptyUdid() {
        let session = BridgeSession(token: "secret", localPort: 1, remotePort: 8080)
        BridgeSessionStore.write(session, udid: "", home: tempHome)
        // Empty-udid directory would be `~/.sim-use/` itself; just
        // ensure no `bridge.json` lands directly under tempHome's
        // `.sim-use/` root.
        let path = tempHome.appendingPathComponent(".sim-use/bridge.json").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - Round-trip (regression guard for legit UDIDs)

    func testRoundTripValidUdid() {
        let session = BridgeSession(token: "abc", localPort: 9999, remotePort: 8080)
        BridgeSessionStore.write(session, udid: "emulator-5554", home: tempHome)
        let loaded = BridgeSessionStore.read(udid: "emulator-5554", home: tempHome)
        XCTAssertEqual(loaded?.token, "abc")
        XCTAssertEqual(loaded?.localPort, 9999)
    }

    /// Real-device serials carry colon-separated transport identifiers
    /// on Wi-Fi (`192.168.1.5:5555`) and underscores on some emulator
    /// builds — both must pass the validator.
    func testRoundTripAcceptsRealisticSerials() {
        let session = BridgeSession(token: "x", localPort: 1, remotePort: 8080)
        for udid in ["192.168.1.5:5555", "R5CT_1ABCD12", "emulator-5556"] {
            BridgeSessionStore.write(session, udid: udid, home: tempHome)
            let loaded = BridgeSessionStore.read(udid: udid, home: tempHome)
            XCTAssertNotNil(loaded, "serial \(udid) should be accepted")
        }
    }
}