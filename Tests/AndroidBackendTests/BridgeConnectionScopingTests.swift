// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AndroidBackend

/// A persisted bridge session (forwarded port + bearer token) is only
/// valid for the adb server that created the forward. These tests pin
/// that a session is never replayed against a different connection —
/// switched adb server, a cache written before sessions recorded their
/// connection, or a cached port now answered by something other than
/// our forward — so the token is never sent to an unrelated listener.
///
/// `adb` is a recording shell script; HTTP goes through a URLProtocol
/// that answers every request like a live listener would and records
/// where it went and which token it carried.
final class BridgeConnectionScopingTests: XCTestCase {
    private let serial = "emulator-5554"
    private let serverA = ["ADB_SERVER_SOCKET": "tcp:192.0.2.10:5037"]
    private let serverB = ["ADB_SERVER_SOCKET": "tcp:192.0.2.20:5037"]

    private var root: URL!
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var adbLog: URL { root.appendingPathComponent("adb.log") }
    private var forwardList: URL { root.appendingPathComponent("forwards.txt") }
    private var failForwardList = false
    private var remotePort = 8080
    private var serverError = false

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-bridge-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        RecordingBridgeProtocol.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Regressions

    func testWarmOperationsDoNotRunAdb() throws {
        let client = try makeClient(environment: [:])
        RecordingBridgeProtocol.treeBody = #"{"status":"success","display":{"width":100,"height":200},"result":[]}"#
        _ = try client.displayInfo()
        let coldCalls = adbCalls()

        _ = try client.ping()
        _ = try client.fetchTreeRaw()
        try client.pressKey(3)
        _ = try client.displayInfo()

        XCTAssertEqual(adbCalls(), coldCalls, "warm operations must not query adb")
    }

    /// Session written against server A, client now pointed at server B:
    /// the cached port and token must not be used, even though a
    /// listener answers on B at A's old port.
    func testSwitchingAdbServerRecreatesForwardAndToken() throws {
        persistSession(token: "token-A", localPort: 18080, environment: serverA)

        try makeClient(environment: serverB).pressKey(3)

        assertNothingSent(toPort: 18080, withToken: "token-A")
        XCTAssertFalse(adbCalls().contains { $0.contains("forward --remove") })
        assertAllRequests(host: "192.0.2.20", port: 18081, authorizedWith: "token-B")
        XCTAssertTrue(adbCalls().contains { $0.contains("forward tcp:0 tcp:8080") }, "a new forward must be created")
        XCTAssertTrue(adbCalls().contains { $0.contains("content query") }, "the token must be fetched again")
    }

    /// A `bridge.json` from before sessions recorded their connection
    /// cannot prove which adb server it belongs to.
    func testLegacySessionWithoutConnectionIsNotReused() throws {
        let legacy = #"{"token":"token-A","localPort":18080,"remotePort":8080,"writtenAt":"2026-09-01T00:00:00Z"}"#
        let file = BridgeSessionStore.file(for: serial, home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: file)

        try makeClient(environment: [:]).pressKey(3)

        assertNothingSent(toPort: 18080, withToken: "token-A")
        assertAllRequests(host: "127.0.0.1", port: 18081, authorizedWith: "token-B")
    }

    /// Same connection, but the cached port is no longer our forward
    /// (it is answered by an unrelated listener): responding is not
    /// proof of identity, so the forward and token are recreated.
    func testUnrelatedListenerOnCachedPortIsNotTrusted() throws {
        persistSession(token: "token-A", localPort: 18080, environment: [:])
        try "other-device tcp:18080 tcp:8080\n".write(to: forwardList, atomically: true, encoding: .utf8)

        try makeClient(environment: [:]).pressKey(3)

        assertNothingSent(toPort: 18080, withToken: "token-A")
        assertAllRequests(host: "127.0.0.1", port: 18081, authorizedWith: "token-B")
    }

    /// Same connection and the forward is still registered for this
    /// serial, but the session has no recorded discovery (an older
    /// release wrote it): discovery confirms the device port and token.
    func testMatchingSessionWithLiveForwardIsReused() throws {
        persistSession(token: "token-A", localPort: 18080, environment: serverA)
        try "\(serial) tcp:18080 tcp:8080\n".write(to: forwardList, atomically: true, encoding: .utf8)

        try makeClient(environment: serverA).pressKey(3)

        assertAllRequests(host: "192.0.2.10", port: 18080, authorizedWith: "token-B")
        XCTAssertFalse(adbCalls().contains { $0.contains("forward tcp:0") }, "no new forward expected")
        XCTAssertTrue(adbCalls().contains { $0.contains("content query") }, "provider must confirm the endpoint")
    }

    /// The rewritten session records the connection it was created for.
    func testRecreatedSessionRecordsItsConnection() throws {
        persistSession(token: "token-A", localPort: 18080, environment: serverA)

        try makeClient(environment: serverB).pressKey(3)

        let stored = try XCTUnwrap(BridgeSessionStore.read(udid: serial, home: home))
        XCTAssertEqual(stored.localPort, 18081)
        XCTAssertEqual(stored.token, "token-B")
        XCTAssertEqual(stored.connection, BridgeConnection(environment: serverB).identity)
        XCTAssertEqual(stored.adbServer, BridgeConnection(environment: serverB).adbServer)
    }

    func testHostOnlyChangeRemovesOldForwardBeforeReplacement() throws {
        persistSession(token: "token-A", localPort: 18080, environment: serverA)
        try "\(serial) tcp:18080 tcp:8080\n".write(to: forwardList, atomically: true, encoding: .utf8)
        var changed = serverA
        changed["SIM_USE_BRIDGE_HOST"] = "192.0.2.30"

        try makeClient(environment: changed).pressKey(3)

        let calls = adbCalls()
        let removal = try XCTUnwrap(calls.firstIndex(of: "-s \(serial) forward --remove tcp:18080"))
        let creation = try XCTUnwrap(calls.firstIndex { $0.contains("forward tcp:0") })
        XCTAssertLessThan(removal, creation)
        assertNothingSent(toPort: 18080, withToken: "token-A")
        assertAllRequests(host: "192.0.2.30", port: 18081, authorizedWith: "token-B")
    }

    func testLegacyUnnormalisedIdentityWithoutServerIsRejectedWithoutRemoval() throws {
        let session = BridgeSession(token: "token-A", localPort: 18080, remotePort: 8080,
                                    connection: "adb=default host=127.0.0.1")
        BridgeSessionStore.write(session, udid: serial, home: home)
        XCTAssertNil(BridgeSessionStore.read(udid: serial, home: home)?.adbServer)

        try makeClient(environment: [:]).pressKey(3)

        assertNothingSent(toPort: 18080, withToken: "token-A")
        XCTAssertFalse(adbCalls().contains { $0.contains("forward --remove") })
    }

    func testDefaultPortChangeReusesSession() throws {
        persistSession(token: "token-A", localPort: 18080, environment: [:])
        try "\(serial) tcp:18080 tcp:8080\n".write(to: forwardList, atomically: true, encoding: .utf8)

        try makeClient(environment: ["ANDROID_ADB_SERVER_PORT": "5037"]).pressKey(3)

        assertAllRequests(host: "127.0.0.1", port: 18080, authorizedWith: "token-B")
        XCTAssertFalse(adbCalls().contains { $0.contains("forward --remove") || $0.contains("forward tcp:0") })
    }

    func testEquivalentDefaultDaemonIdentities() {
        XCTAssertEqual(
            BridgeConnection.daemonConnectionIdentity(udid: serial, environment: [:]),
            BridgeConnection.daemonConnectionIdentity(udid: serial, environment: ["ANDROID_ADB_SERVER_PORT": "5037"])
        )
    }

    func testAdbServerNormalisation() {
        for spec in ["default", "tcp:5037", "tcp:localhost:5037", "tcp:127.0.0.1:5037", "tcp:[::1]:5037"] {
            XCTAssertEqual(BridgeConnection.normalizeAdbServer(spec), "tcp:localhost:5037", spec)
        }
        for address in ["localhost", "127.0.0.1", "::1", "[::1]"] {
            for port in [nil, "5037", ""] as [String?] {
                var environment = ["ANDROID_ADB_SERVER_ADDRESS": address]
                environment["ANDROID_ADB_SERVER_PORT"] = port
                XCTAssertEqual(BridgeConnection(environment: environment).adbServer, "tcp:localhost:5037")
            }
        }
        for (spec, expected) in [
            ("tcp:5038", "tcp:localhost:5038"),
            ("tcp:192.0.2.10:5037", "tcp:192.0.2.10:5037"),
            ("tcp:ADB.EXAMPLE:5037", "tcp:adb.example:5037"),
            ("tcp:[fd00::1]:5037", "tcp:[fd00::1]:5037"),
            ("tcp:bad-port", "tcp:bad-port"),
            ("tcp:localhost:nope", "tcp:localhost:nope"),
            ("tcp:localhost:70000", "tcp:localhost:70000"),
            ("localfilesystem:/tmp/adb.sock", "localfilesystem:/tmp/adb.sock"),
        ] {
            XCTAssertEqual(BridgeConnection.normalizeAdbServer(spec), expected)
        }
        XCTAssertEqual(BridgeConnection(environment: ["ANDROID_ADB_SERVER_ADDRESS": "192.0.2.10"]).adbServer,
                       "tcp:192.0.2.10:5037")
    }

    // MARK: - Connection identity

    func testIdentityTracksEveryVariableThatMovesTheConnection() {
        let base = BridgeConnection(environment: [:]).identity
        XCTAssertEqual(BridgeConnection(environment: ["ADB_SERVER_SOCKET": ""]).identity, base, "empty equals unset")
        for env in [
            serverA,
            ["ANDROID_ADB_SERVER_ADDRESS": "192.0.2.10"],
            ["ANDROID_ADB_SERVER_PORT": "5038"],
            ["SIM_USE_BRIDGE_HOST": "192.0.2.30"],
        ] {
            XCTAssertNotEqual(BridgeConnection(environment: env).identity, base, "\(env) must change the identity")
        }
        XCTAssertNotEqual(BridgeConnection(environment: serverA).identity, BridgeConnection(environment: serverB).identity)
    }

    func testDaemonIdentityIsScopedToAndroidTargets() {
        XCTAssertNotNil(BridgeConnection.daemonConnectionIdentity(udid: serial, environment: serverA))
        XCTAssertNotEqual(
            BridgeConnection.daemonConnectionIdentity(udid: serial, environment: serverA),
            BridgeConnection.daemonConnectionIdentity(udid: serial, environment: serverB)
        )
        XCTAssertNil(
            BridgeConnection.daemonConnectionIdentity(udid: "1A2B3C4D-1A2B-1A2B-1A2B-1A2B3C4D5E6F", environment: serverA),
            "iOS simulator daemons do not depend on the adb connection"
        )
        XCTAssertNil(
            BridgeConnection.daemonConnectionIdentity(udid: "00008130-00066D2A10EB8D3A", environment: serverA),
            "physical iOS devices do not depend on the adb connection"
        )
    }

    /// Any serial adb can hand out reaches the per-device daemon, not just
    /// the shapes `PlatformRouter.looksLikeAndroid` recognises — wireless
    /// debugging (mDNS) serials run past its 32-character cap. Those
    /// daemons talk to adb all the same, so they must be scoped too.
    func testDaemonIdentityCoversSerialsOutsideTheAndroidHeuristic() {
        for udid in [
            "adb-R58M123ABC-AbCdEf._adb-tls-connect._tcp",
            "adb-R58M123ABC-AbCdEf._adb-tls-connect._tcp.",
            "192.0.2.5:5555",
        ] {
            let a = BridgeConnection.daemonConnectionIdentity(udid: udid, environment: serverA)
            let b = BridgeConnection.daemonConnectionIdentity(udid: udid, environment: serverB)
            XCTAssertNotNil(a, "\(udid) must carry a connection identity")
            XCTAssertNotEqual(a, b, "\(udid) must follow the adb server")
        }
    }

    /// `adb forward --list` failing says nothing about whether the cached
    /// forward is gone. Treating it as gone would open another forward on
    /// every such failure and strand the old one on the adb server, so
    /// the failure surfaces instead and the session is kept for the next
    /// call to confirm.
    func testForwardListFailureDoesNotOpenAnotherForward() throws {
        persistSession(token: "token-A", localPort: 18080, environment: serverA)
        failForwardList = true

        XCTAssertThrowsError(try makeClient(environment: serverA).pressKey(3))

        XCTAssertFalse(adbCalls().contains { $0.contains("forward tcp:0") }, "no new forward expected: \(adbCalls())")
        XCTAssertTrue(RecordingBridgeProtocol.requests().isEmpty, "unconfirmed forward must not be used")
        let stored = try XCTUnwrap(BridgeSessionStore.read(udid: serial, home: home))
        XCTAssertEqual(stored.localPort, 18080)
        XCTAssertEqual(stored.token, "token-A")
    }

    /// A forward that is confirmed gone is not ours to reuse, and there
    /// is nothing left on the server to clean up: the replacement is the
    /// only forward opened.
    func testConfirmedMissingForwardOpensExactlyOneReplacement() throws {
        persistSession(token: "token-A", localPort: 18080, environment: serverA)

        try makeClient(environment: serverA).pressKey(3)

        XCTAssertEqual(adbCalls().filter { $0.contains("forward tcp:0") }.count, 1, "\(adbCalls())")
        assertAllRequests(host: "192.0.2.10", port: 18081, authorizedWith: "token-B")
    }

    /// With more than one device on the adb server, `adb forward --remove`
    /// without `-s` fails ("more than one device/emulator"), so dropping a
    /// forward has to name the serial or the forward is left behind.
    func testInvalidateRemovesTheForwardForThisSerial() throws {
        let client = try makeClient(environment: serverA)
        try client.pressKey(3)

        client.invalidate()

        XCTAssertTrue(
            adbCalls().contains("-s \(serial) forward --remove tcp:18081"),
            "forward must be removed for this serial: \(adbCalls())"
        )
    }

    /// Nothing answers on the bridge port, even after reconnecting:
    /// both attempts must remove their forward for this serial, since
    /// no persisted session will be available to clean it up later.
    func testFailedReconnectRemovesEveryCreatedForward() throws {
        RecordingBridgeProtocol.reset(listenerAvailable: false)
        let client = try makeClient(environment: serverA)

        XCTAssertThrowsError(try client.ping())

        let calls = adbCalls()
        let creations = calls.filter { $0 == "-s \(serial) forward tcp:0 tcp:8080" }
        let removals = calls.filter { $0 == "-s \(serial) forward --remove tcp:18081" }
        XCTAssertEqual(creations.count, 2, "initial attempt and reconnect must each open a forward: \(calls)")
        XCTAssertEqual(removals.count, creations.count, "every created forward must be removed for this serial: \(calls)")
        XCTAssertNil(BridgeSessionStore.read(udid: serial, home: home))
    }

    func testFallbackPortIsForwardedPersistedRestoredAndRemoved() throws {
        remotePort = 49152
        let client = try makeClient(environment: serverA)
        _ = try client.ping()
        XCTAssertTrue(adbCalls().contains("-s \(serial) forward tcp:0 tcp:49152"))
        XCTAssertEqual(BridgeSessionStore.read(udid: serial, home: home)?.remotePort, 49152)
        try "\(serial) tcp:18081 tcp:49152\n".write(to: forwardList, atomically: true, encoding: .utf8)
        let restored = try makeClient(environment: serverA)
        _ = try restored.ping()
        XCTAssertEqual(adbCalls().filter { $0.contains("forward tcp:0") }.count, 1)
        restored.invalidate()
        XCTAssertTrue(adbCalls().contains("-s \(serial) forward --remove tcp:18081"))
    }

    func testMigratedCachedEndpointNeverReceivesToken() throws {
        RecordingBridgeProtocol.rejectPort = 18080
        remotePort = 49153
        let session = BridgeSession(token: "token-A", localPort: 18080, remotePort: 49152,
            connection: BridgeConnection(environment: [:]).identity,
            adbServer: BridgeConnection(environment: [:]).adbServer)
        BridgeSessionStore.write(session, udid: serial, home: home)
        try "\(serial) tcp:18080 tcp:49152\n".write(to: forwardList, atomically: true, encoding: .utf8)
        try makeClient(environment: [:]).pressKey(3)
        assertNothingSent(toPort: 18080, withToken: "token-A")
        XCTAssertTrue(adbCalls().contains("-s \(serial) forward --remove tcp:18080"))
        let stored = try XCTUnwrap(BridgeSessionStore.read(udid: serial, home: home))
        XCTAssertEqual(stored.remotePort, 49153)
        XCTAssertEqual(stored.token, "token-B")
    }

    func testHandshakeHTTPFailureRediscoveryIsBoundedAndReachesOldListener() throws {
        for status in [404, 401, 500, 200] {
            // Each status starts cold: no session or forward from the last one.
            RecordingBridgeProtocol.reset()
            BridgeSessionStore.invalidate(udid: serial, home: home)
            try? FileManager.default.removeItem(at: forwardList)
            remotePort = 49152
            let client = try makeClient(environment: [:])
            _ = try client.ping()
            let script = root.appendingPathComponent("adb")
            let replacement = try String(contentsOf: script, encoding: .utf8)
                .replacingOccurrences(of: "49152", with: "49153")
                .replacingOccurrences(of: "18081", with: "18082")
            RecordingBridgeProtocol.rejectPort = 18081
            RecordingBridgeProtocol.oldStatus = status
            RecordingBridgeProtocol.onRejected = {
                try! replacement.write(to: script, atomically: true, encoding: .utf8)
                try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            }
            _ = try client.ping(force: true)
            try client.pressKey(3)
            let requests = RecordingBridgeProtocol.requests()
            XCTAssertEqual(requests.filter { $0.port == 18081 && $0.path == "/ping" }.count, 2,
                "initial success plus the actual HTTP failure")
            XCTAssertFalse(requests.contains { $0.port == 18081 && $0.authorization != nil })
            XCTAssertEqual(BridgeSessionStore.read(udid: serial, home: home)?.remotePort, 49153)
            XCTAssertTrue(adbCalls().contains("-s \(serial) forward --remove tcp:18081"))
        }
    }

    func testPendingActionUsesEndpointDiscoveredByHandshake() throws {
        remotePort = 49152
        let client = try makeClient(environment: [:])
        let script = root.appendingPathComponent("adb")
        let replacement = try String(contentsOf: script, encoding: .utf8)
            .replacingOccurrences(of: "49152", with: "49153")
            .replacingOccurrences(of: "18081", with: "18082")
        RecordingBridgeProtocol.rejectPort = 18081
        RecordingBridgeProtocol.oldStatus = 401
        RecordingBridgeProtocol.onRejected = {
            try! replacement.write(to: script, atomically: true, encoding: .utf8)
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }

        try client.pressKey(3)

        let actions = RecordingBridgeProtocol.requests().filter { $0.path == "/keyboard/key" }
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.port, 18082)
        XCTAssertFalse(RecordingBridgeProtocol.requests().contains {
            $0.port == 18081 && $0.authorization != nil
        })
    }

    func testUncertainActionTransportFailuresDoNotReplay() throws {
        let client = try makeClient(environment: [:])
        for code in [URLError.Code.networkConnectionLost, .timedOut, .cancelled] {
            RecordingBridgeProtocol.reset()
            RecordingBridgeProtocol.businessTransportError = code
            RecordingBridgeProtocol.businessFailuresRemaining = 1
            XCTAssertThrowsError(try client.pressKey(3))
            XCTAssertEqual(RecordingBridgeProtocol.requests().filter { $0.path == "/keyboard/key" }.count, 1)
        }
    }

    func testUnauthorizedActionHasOneRetryLimit() throws {
        RecordingBridgeProtocol.businessStatus = 401
        XCTAssertThrowsError(try makeClient(environment: [:]).pressKey(3))
        XCTAssertEqual(RecordingBridgeProtocol.requests().filter { $0.path == "/keyboard/key" }.count, 2)
        XCTAssertNil(BridgeSessionStore.read(udid: serial, home: home))
    }

    func testHandshakeRediscoveryIsBounded() throws {
        RecordingBridgeProtocol.rejectPort = 18081
        RecordingBridgeProtocol.oldStatus = 404
        XCTAssertThrowsError(try makeClient(environment: [:]).ping())
        XCTAssertEqual(RecordingBridgeProtocol.requests().count, 2)
        XCTAssertNil(BridgeSessionStore.read(udid: serial, home: home))
    }

    func testBusinessFailureDoesNotReplayAction() throws {
        RecordingBridgeProtocol.businessStatus = 500
        XCTAssertThrowsError(try makeClient(environment: [:]).pressKey(3))
        XCTAssertEqual(RecordingBridgeProtocol.requests().filter { $0.path == "/keyboard/key" }.count, 1)
    }

    func testBindExhaustionDoesNotCreateForward() throws {
        serverError = true
        let client = try makeClient(environment: serverA)
        XCTAssertThrowsError(try client.ping()) { error in
            XCTAssertTrue(error.localizedDescription.contains("ports are occupied"))
        }
        XCTAssertFalse(adbCalls().contains { $0.contains("forward tcp:0") })
        XCTAssertNil(BridgeSessionStore.read(udid: serial, home: home))
    }

    func testWarmGETDiscoversMigrationAfterConnectionRefusal() throws {
        remotePort = 49152
        let client = try makeClient(environment: [:])
        _ = try client.ping()
        RecordingBridgeProtocol.reset()
        remotePort = 49153
        try writeAdbFixture()
        RecordingBridgeProtocol.rejectPort = 18081
        RecordingBridgeProtocol.rejectedTransportError = .cannotConnectToHost
        _ = try client.ping()
        _ = try client.fetchTreeRaw()
        _ = try client.fetchTreeRaw()
        XCTAssertEqual(RecordingBridgeProtocol.requests().filter { $0.port == 18081 }.count, 1)
        XCTAssertEqual(BridgeSessionStore.read(udid: serial, home: home)?.remotePort, 49153)
    }

    func testWarmActionDiscoversMigrationAfterUnauthorizedResponse() throws {
        remotePort = 49152
        let client = try makeClient(environment: [:])
        try client.pressKey(3)
        RecordingBridgeProtocol.reset()
        remotePort = 49153
        try writeAdbFixture()
        RecordingBridgeProtocol.rejectPort = 18081
        RecordingBridgeProtocol.oldStatus = 401
        try client.pressKey(3)
        let actions = RecordingBridgeProtocol.requests().filter { $0.path == "/keyboard/key" }
        XCTAssertEqual(actions.filter { $0.port == 18081 }.count, 1)
        XCTAssertEqual(actions.filter { $0.port == 18082 }.count, 1)
    }

    func testPortMigrationDoesNotRemoveReusedLocalForward() throws {
        for other in ["other-device tcp:18080 tcp:9000", "\(serial) tcp:18080 tcp:9000"] {
            let session = BridgeSession(token: "token-A", localPort: 18080, remotePort: 49152,
                connection: BridgeConnection(environment: [:]).identity,
                adbServer: BridgeConnection(environment: [:]).adbServer)
            BridgeSessionStore.write(session, udid: serial, home: home)
            try "\(other)\n".write(to: forwardList, atomically: true, encoding: .utf8)
            remotePort = 49153
            _ = try makeClient(environment: [:]).ping()
            XCTAssertFalse(adbCalls().contains { $0.contains("--remove tcp:18080") })
        }
    }

    func testPortMigrationWithListFailurePreservesUnconfirmedSession() throws {
        let session = BridgeSession(token: "token-A", localPort: 18080, remotePort: 49152,
            connection: BridgeConnection(environment: [:]).identity,
            adbServer: BridgeConnection(environment: [:]).adbServer)
        BridgeSessionStore.write(session, udid: serial, home: home)
        remotePort = 49153
        failForwardList = true
        let client = try makeClient(environment: [:])
        XCTAssertThrowsError(try client.ping())
        XCTAssertFalse(adbCalls().contains { $0.contains("forward --remove") || $0.contains("forward tcp:0") })
        XCTAssertEqual(BridgeSessionStore.read(udid: serial, home: home)?.remotePort, 49152)
        XCTAssertTrue(RecordingBridgeProtocol.requests().isEmpty)
        // Retrying the same client must still validate its unconfirmed session.
        failForwardList = false
        try "\(serial) tcp:18080 tcp:49152\n".write(to: forwardList, atomically: true, encoding: .utf8)
        try writeAdbFixture()
        _ = try client.ping()
        XCTAssertTrue(adbCalls().contains { $0.contains("--remove tcp:18080") })
    }

    func testRefusedActionConnectionReconnectsOnce() throws {
        let client = try makeClient(environment: [:])
        _ = try client.ping()
        RecordingBridgeProtocol.businessTransportError = .cannotConnectToHost
        RecordingBridgeProtocol.businessFailuresRemaining = 1
        try client.pressKey(3)
        XCTAssertEqual(RecordingBridgeProtocol.requests().filter { $0.path == "/keyboard/key" }.count, 2)
    }

    func testConcurrentActionsShareAnAtomicEndpointTransition() async throws {
        remotePort = 49152
        let client = try makeClient(environment: [:])
        _ = try client.ping()
        RecordingBridgeProtocol.reset()
        remotePort = 49153
        try writeAdbFixture()
        RecordingBridgeProtocol.rejectPort = 18081
        RecordingBridgeProtocol.rejectedTransportError = .cannotConnectToHost
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { try client.pressKey(3) } }
            try await group.waitForAll()
        }
        let requests = RecordingBridgeProtocol.requests()
        XCTAssertEqual(requests.filter { $0.path == "/keyboard/key" && $0.port == 18082 }.count, 4)
        XCTAssertEqual(adbCalls().filter { $0.contains("forward tcp:0 tcp:49153") }.count, 1)
    }

    func testRefusedActionReconnectHasOneRetryLimit() throws {
        let client = try makeClient(environment: [:])
        _ = try client.ping()
        RecordingBridgeProtocol.businessTransportError = .cannotConnectToHost
        RecordingBridgeProtocol.businessFailuresRemaining = 3
        XCTAssertThrowsError(try client.pressKey(3))
        XCTAssertEqual(RecordingBridgeProtocol.requests().filter { $0.path == "/keyboard/key" }.count, 2)
    }

    func testRestoredEndpointUsesFreshTokenAndSingleDiscovery() throws {
        persistSession(token: "token-A", localPort: 18080, environment: [:])
        try "\(serial) tcp:18080 tcp:8080\n".write(to: forwardList, atomically: true, encoding: .utf8)
        try makeClient(environment: [:]).pressKey(3)
        XCTAssertEqual(adbCalls().filter { $0.contains("content query") }.count, 1)
        XCTAssertTrue(RecordingBridgeProtocol.requests().contains { $0.authorization == "Bearer token-B" })
        XCTAssertFalse(RecordingBridgeProtocol.requests().contains { $0.authorization == "Bearer token-A" })
    }

    // MARK: - Recent discovered sessions

    /// A new process reuses a session that a recent provider discovery
    /// created: the only adb call is the forward ownership check.
    func testRecentDiscoveredSessionIsReusedWithoutProviderQuery() throws {
        persistSession(token: "token-A", localPort: 18080, environment: [:], discoveredAt: Date().addingTimeInterval(-300))
        try "\(serial) tcp:18080 tcp:8080\n".write(to: forwardList, atomically: true, encoding: .utf8)
        let stored = BridgeSessionStore.read(udid: serial, home: home)

        try makeClient(environment: [:]).pressKey(3)

        assertAllRequests(host: "127.0.0.1", port: 18080, authorizedWith: "token-A")
        XCTAssertEqual(adbCalls(), ["forward --list"])
        XCTAssertEqual(BridgeSessionStore.read(udid: serial, home: home), stored,
                       "reuse must not extend the trust window")
    }

    func testSessionOutsideTheTrustWindowRequiresDiscovery() throws {
        let window = BridgeClient.restoredSessionTrustWindow
        for discoveredAt in [nil, Date().addingTimeInterval(-window - 1), Date().addingTimeInterval(120)] {
            RecordingBridgeProtocol.reset()
            try? FileManager.default.removeItem(at: adbLog)
            persistSession(token: "token-A", localPort: 18080, environment: [:], discoveredAt: discoveredAt)
            try "\(serial) tcp:18080 tcp:8080\n".write(to: forwardList, atomically: true, encoding: .utf8)

            try makeClient(environment: [:]).pressKey(3)

            XCTAssertEqual(adbCalls().filter { $0.contains("content query") }.count, 1, "\(String(describing: discoveredAt))")
            assertAllRequests(host: "127.0.0.1", port: 18080, authorizedWith: "token-B")
            XCTAssertFalse(RecordingBridgeProtocol.requests().contains { $0.authorization == "Bearer token-A" })
        }
    }

    func testRecentSessionWithoutOwnedForwardRequiresDiscovery() throws {
        persistSession(token: "token-A", localPort: 18080, environment: [:], discoveredAt: Date())
        try "other-device tcp:18080 tcp:8080\n".write(to: forwardList, atomically: true, encoding: .utf8)

        try makeClient(environment: [:]).pressKey(3)

        assertNothingSent(toPort: 18080, withToken: "token-A")
        assertAllRequests(host: "127.0.0.1", port: 18081, authorizedWith: "token-B")
    }

    /// The handshake carries no bearer. A reused session whose port now
    /// belongs to another listener fails there and is discovered again.
    func testRecentSessionOnUnrelatedListenerRediscoversBeforeBearer() throws {
        persistSession(token: "token-A", localPort: 18080, environment: [:], discoveredAt: Date())
        try "\(serial) tcp:18080 tcp:8080\n".write(to: forwardList, atomically: true, encoding: .utf8)
        RecordingBridgeProtocol.rejectPort = 18080
        RecordingBridgeProtocol.oldStatus = 404

        try makeClient(environment: [:]).pressKey(3)

        let requests = RecordingBridgeProtocol.requests()
        XCTAssertFalse(requests.contains { $0.port == 18080 && $0.authorization != nil })
        XCTAssertFalse(requests.contains { $0.authorization == "Bearer token-A" })
        XCTAssertTrue(requests.contains { $0.port == 18081 && $0.authorization == "Bearer token-B" })
        XCTAssertTrue(adbCalls().contains("-s \(serial) forward --remove tcp:18080"))
    }

    /// `init` restarts the bridge, so it must discover even when a recent
    /// session exists. It discovers once and reports the connected port.
    func testConnectAfterBridgeStartDiscoversOnceDespiteRecentSession() throws {
        persistSession(token: "token-A", localPort: 18080, environment: [:], discoveredAt: Date())
        try "\(serial) tcp:18080 tcp:8080\n".write(to: forwardList, atomically: true, encoding: .utf8)
        let client = try makeClient(environment: [:])

        let connected = try client.connectAfterBridgeStart(startupTimeout: 0.2)
        try client.pressKey(3)

        XCTAssertEqual(connected.remotePort, 8080)
        XCTAssertEqual(connected.ping.protocolVersion, BridgeClient.expectedProtocolVersion)
        XCTAssertEqual(adbCalls().filter { $0.contains("content query") }.count, 1)
        XCTAssertFalse(adbCalls().contains { $0.contains("forward tcp:0") }, "the owned forward must be reused")
        assertAllRequests(host: "127.0.0.1", port: 18080, authorizedWith: "token-B")
    }

    // MARK: - Responses from another listener

    /// Every bridge error is a JSON envelope. Another response shape means
    /// that another listener owns the cached port, so a GET discovers again.
    func testWarmGETRecoversAfterResponseFromAnotherListener() throws {
        remotePort = 49152
        let client = try makeClient(environment: [:])
        _ = try client.ping()
        RecordingBridgeProtocol.reset()
        remotePort = 49153
        try writeAdbFixture()
        RecordingBridgeProtocol.rejectPort = 18081
        RecordingBridgeProtocol.oldStatus = 404

        _ = try client.fetchTreeRaw()
        _ = try client.fetchTreeRaw()

        let requests = RecordingBridgeProtocol.requests()
        XCTAssertEqual(requests.filter { $0.port == 18081 }.count, 1)
        XCTAssertEqual(requests.filter { $0.port == 18082 && $0.path == "/a11y_tree_full" }.count, 2)
        XCTAssertEqual(BridgeSessionStore.read(udid: serial, home: home)?.remotePort, 49153)
    }

    /// The same response on a POST is reported without replay, but the next
    /// request must not reach the other listener again.
    func testWarmActionDiscardsEndpointAfterResponseFromAnotherListener() throws {
        remotePort = 49152
        let client = try makeClient(environment: [:])
        try client.pressKey(3)
        RecordingBridgeProtocol.reset()
        remotePort = 49153
        try writeAdbFixture()
        RecordingBridgeProtocol.rejectPort = 18081
        RecordingBridgeProtocol.oldStatus = 404

        XCTAssertThrowsError(try client.pressKey(3)) {
            guard case BridgeError.httpStatus(let code, _) = $0 else { return XCTFail("Unexpected error: \($0)") }
            XCTAssertEqual(code, 404)
        }
        try client.pressKey(3)

        let actions = RecordingBridgeProtocol.requests().filter { $0.path == "/keyboard/key" }
        XCTAssertEqual(actions.filter { $0.port == 18081 }.count, 1)
        XCTAssertEqual(actions.filter { $0.port == 18082 }.count, 1)
    }

    /// A bridge error envelope is a business result: the endpoint stays.
    func testBridgeErrorEnvelopeKeepsTheEndpoint() throws {
        let client = try makeClient(environment: [:])
        try client.pressKey(3)
        let warmCalls = adbCalls()
        RecordingBridgeProtocol.businessStatus = 500

        XCTAssertThrowsError(try client.pressKey(3))

        XCTAssertEqual(adbCalls(), warmCalls)
        XCTAssertNotNil(BridgeSessionStore.read(udid: serial, home: home))
    }

    // MARK: - Shared disk session

    /// Another process replaced the forward and the disk session after a
    /// port change. This client must use that forward, not strand it.
    func testReplacedDiskSessionIsAdoptedInsteadOfLeakingAForward() throws {
        let client = try makeClient(environment: [:])
        try client.pressKey(3)
        let warmCalls = adbCalls().count
        RecordingBridgeProtocol.reset()
        try "\(serial) tcp:18090 tcp:49153\n".write(to: forwardList, atomically: true, encoding: .utf8)
        BridgeSessionStore.write(BridgeSession(
            token: "token-C", localPort: 18090, remotePort: 49153,
            connection: BridgeConnection(environment: [:]).identity,
            adbServer: BridgeConnection(environment: [:]).adbServer,
            discoveredAt: Date()
        ), udid: serial, home: home)
        remotePort = 49153
        try writeAdbFixture()
        RecordingBridgeProtocol.rejectPort = 18081
        RecordingBridgeProtocol.rejectedTransportError = .cannotConnectToHost

        try client.pressKey(3)

        let recovery = Array(adbCalls().dropFirst(warmCalls))
        XCTAssertFalse(recovery.contains { $0.contains("forward tcp:0") || $0.contains("forward --remove") }, "\(recovery)")
        XCTAssertFalse(recovery.contains { $0.contains("content query") }, "\(recovery)")
        XCTAssertTrue(RecordingBridgeProtocol.requests().contains {
            $0.port == 18090 && $0.path == "/keyboard/key" && $0.authorization == "Bearer token-C"
        })
        XCTAssertEqual(BridgeSessionStore.read(udid: serial, home: home)?.localPort, 18090)
    }

    func testOldDisplayResponseCannotOverwriteReplacementCache() async throws {
        remotePort = 49152
        let client = try makeClient(environment: [:])
        let received = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        RecordingBridgeProtocol.treeBody = #"{"status":"success","display":{"width":100,"height":200},"result":[]}"#
        RecordingBridgeProtocol.responseGate = release
        RecordingBridgeProtocol.onResponseWaiting = { received.signal() }
        let oldRead = Task.detached {
            return try client.displayInfo()
        }
        XCTAssertEqual(received.wait(timeout: .now() + 10), .success)
        // Invalidation and a second HTTP call must complete while the first is blocked.
        client.invalidate()
        remotePort = 49153
        try writeAdbFixture()
        RecordingBridgeProtocol.responseGate = nil
        RecordingBridgeProtocol.treeBody = #"{"status":"success","display":{"width":300,"height":400},"result":[]}"#
        let newDisplay = try client.displayInfo()
        release.signal()
        let oldDisplay = try await oldRead.value
        XCTAssertEqual(oldDisplay, DisplayMetrics(width: 100, height: 200))
        XCTAssertEqual(newDisplay, DisplayMetrics(width: 300, height: 400))
        XCTAssertEqual(try client.displayInfo(), DisplayMetrics(width: 300, height: 400))
    }

    func testOldActionFailureDoesNotRemoveReplacementSession() async throws {
        let client = try makeClient(environment: [:])
        _ = try client.ping()
        let received = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        RecordingBridgeProtocol.responseGate = release
        RecordingBridgeProtocol.onResponseWaiting = { received.signal() }
        RecordingBridgeProtocol.businessTransportError = .networkConnectionLost
        RecordingBridgeProtocol.businessFailuresRemaining = 1
        let oldAction = Task.detached { () -> Bool in
            do { try client.pressKey(3); return false }
            catch { return true }
        }
        XCTAssertEqual(received.wait(timeout: .now() + 10), .success)
        client.invalidate()
        remotePort = 49153
        try writeAdbFixture()
        RecordingBridgeProtocol.responseGate = nil
        try client.pressKey(3)
        release.signal()
        let failed = await oldAction.value
        XCTAssertTrue(failed)
        XCTAssertEqual(BridgeSessionStore.read(udid: serial, home: home)?.remotePort, 49153)
        XCTAssertFalse(adbCalls().contains { $0.contains("--remove tcp:18082") })
    }

    func testCleanupListFailurePreservesOriginalHandshakeError() throws {
        let client = try makeClient(environment: [:])
        _ = try client.ping()
        failForwardList = true
        let script = root.appendingPathComponent("adb")
        // Validation succeeds first; the HTTP failure then makes cleanup fail.
        RecordingBridgeProtocol.rejectPort = 18081
        RecordingBridgeProtocol.oldStatus = 404
        let failingScript: String
        try writeAdbFixture()
        failingScript = try String(contentsOf: script, encoding: .utf8)
        failForwardList = false
        try writeAdbFixture()
        RecordingBridgeProtocol.onRejected = {
            try! failingScript.write(to: script, atomically: true, encoding: .utf8)
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        XCTAssertThrowsError(try client.ping(force: true)) {
            guard case BridgeError.httpStatus(let code, _) = $0 else { return XCTFail("Lost original handshake error: \($0)") }
            XCTAssertEqual(code, 404)
        }
    }

    func testCleanupListFailurePreservesActionTransportErrors() throws {
        for code in [URLError.Code.networkConnectionLost, .cannotConnectToHost] {
            RecordingBridgeProtocol.reset()
            let client = try makeClient(environment: [:])
            _ = try client.ping()
            let script = root.appendingPathComponent("adb")
            failForwardList = true
            try writeAdbFixture()
            let failingScript = try String(contentsOf: script, encoding: .utf8)
            failForwardList = false
            try writeAdbFixture()
            RecordingBridgeProtocol.businessTransportError = code
            RecordingBridgeProtocol.businessFailuresRemaining = 1
            RecordingBridgeProtocol.onBusinessFailure = {
                try! failingScript.write(to: script, atomically: true, encoding: .utf8)
                try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            }
            XCTAssertThrowsError(try client.pressKey(3)) {
                guard case BridgeError.transport(let underlying, _) = $0 else { return XCTFail("Lost original transport error: \($0)") }
                XCTAssertEqual(underlying, URLError(code).localizedDescription)
            }
            XCTAssertEqual(RecordingBridgeProtocol.requests().filter { $0.path == "/keyboard/key" }.count, 1)
        }
    }

    // MARK: - Fixtures

    /// `discoveredAt: nil` is the shape that older releases wrote.
    private func persistSession(
        token: String, localPort: Int, environment: [String: String], discoveredAt: Date? = nil
    ) {
        let session = BridgeSession(
            token: token,
            localPort: localPort,
            remotePort: BridgeClient.defaultRemotePort,
            connection: BridgeConnection(environment: environment).identity,
            adbServer: BridgeConnection(environment: environment).adbServer,
            discoveredAt: discoveredAt
        )
        BridgeSessionStore.write(session, udid: serial, home: home)
    }

    private func writeAdbFixture() throws {
        let script = root.appendingPathComponent("adb")
        let body = """
            #!/bin/sh
            echo "$*" >> '\(adbLog.path)'
            case "$*" in
              *"forward --remove"*)
                # Real adb with several devices refuses this without -s.
                [ "$1" = "-s" ] || { echo "adb: error: more than one device/emulator" >&2; exit 1; }
                awk -v local="$5" '$2 != local' '\(forwardList.path)' > '\(forwardList.path).next'
                mv '\(forwardList.path).next' '\(forwardList.path)' ;;
              *"forward --list"*) \(failForwardList ? "echo 'error: cannot connect to daemon' >&2; exit 1" : "cat '\(forwardList.path)' 2>/dev/null") ;;
              *"forward tcp:0 tcp:\(remotePort)"*) echo \(remotePort == 49153 ? 18082 : 18081); echo "\(serial) tcp:\(remotePort == 49153 ? 18082 : 18081) tcp:\(remotePort)" >> '\(forwardList.path)' ;;
              *"pm list packages"*) echo 'package:\(BridgeClient.bridgePackageName)' ;;
              *"content query"*) echo 'Row: 0 result={"result":"token-B","port":\(remotePort)\(serverError ? ",\"server_error\":\"Bridge ports are occupied; inspect adb shell ss -ltnp\"" : "")}' ;;
            esac
            exit 0

            """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    }

    private func makeClient(environment: [String: String]) throws -> BridgeClient {
        try writeAdbFixture()
        let script = root.appendingPathComponent("adb")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingBridgeProtocol.self]
        return BridgeClient(
            adb: Adb(binaryPath: script.path, defaultTimeout: 5),
            serial: serial,
            urlSession: URLSession(configuration: config),
            environment: environment,
            sessionHome: home
        )
    }

    private func adbCalls() -> [String] {
        ((try? String(contentsOf: adbLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func assertNothingSent(toPort port: Int, withToken token: String, file: StaticString = #filePath, line: UInt = #line) {
        let requests = RecordingBridgeProtocol.requests()
        XCTAssertFalse(requests.contains { $0.port == port }, "request reached cached port \(port): \(requests)", file: file, line: line)
        XCTAssertFalse(
            requests.contains { $0.authorization == "Bearer \(token)" },
            "cached token \(token) was sent: \(requests)", file: file, line: line
        )
    }

    private func assertAllRequests(
        host: String, port: Int, authorizedWith token: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let requests = RecordingBridgeProtocol.requests()
        XCTAssertFalse(requests.isEmpty, "no bridge request was made", file: file, line: line)
        for request in requests {
            XCTAssertEqual(request.host, host, "\(request)", file: file, line: line)
            XCTAssertEqual(request.port, port, "\(request)", file: file, line: line)
        }
        XCTAssertTrue(
            requests.contains { $0.authorization == "Bearer \(token)" },
            "expected an authorized request with \(token): \(requests)", file: file, line: line
        )
    }
}

/// Answers bridge requests successfully unless no listener is available,
/// and records where they went.
final class RecordingBridgeProtocol: URLProtocol {
    struct Recorded: CustomStringConvertible {
        let host: String?
        let port: Int?
        let path: String
        let authorization: String?
        var description: String { "\(host ?? "?"):\(port ?? -1)\(path) auth=\(authorization ?? "none")" }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [Recorded] = []
    private struct Settings {
        var listenerAvailable = true
        var oldStatus: Int = 200
        var rejectPort: Int = -1
        var businessStatus: Int = 200
        var onRejected: (() -> Void)? = nil
        var businessTransportError: URLError.Code = .networkConnectionLost
        var businessFailuresRemaining: Int = 0
        var treeBody: String? = nil
        var responseGate: DispatchSemaphore? = nil
        var onResponseWaiting: (() -> Void)? = nil
        var rejectedTransportError: URLError.Code? = nil
        var onBusinessFailure: (() -> Void)? = nil
    }
    nonisolated(unsafe) private static var settings = Settings()

    static var oldStatus: Int {
        get { lock.lock(); defer { lock.unlock() }; return settings.oldStatus }
        set { lock.lock(); defer { lock.unlock() }; settings.oldStatus = newValue }
    }

    static var rejectPort: Int {
        get { lock.lock(); defer { lock.unlock() }; return settings.rejectPort }
        set { lock.lock(); defer { lock.unlock() }; settings.rejectPort = newValue }
    }

    static var businessStatus: Int {
        get { lock.lock(); defer { lock.unlock() }; return settings.businessStatus }
        set { lock.lock(); defer { lock.unlock() }; settings.businessStatus = newValue }
    }

    static var onRejected: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return settings.onRejected }
        set { lock.lock(); defer { lock.unlock() }; settings.onRejected = newValue }
    }

    static var businessTransportError: URLError.Code {
        get { lock.lock(); defer { lock.unlock() }; return settings.businessTransportError }
        set { lock.lock(); defer { lock.unlock() }; settings.businessTransportError = newValue }
    }

    static var businessFailuresRemaining: Int {
        get { lock.lock(); defer { lock.unlock() }; return settings.businessFailuresRemaining }
        set { lock.lock(); defer { lock.unlock() }; settings.businessFailuresRemaining = newValue }
    }

    static var treeBody: String? {
        get { lock.lock(); defer { lock.unlock() }; return settings.treeBody }
        set { lock.lock(); defer { lock.unlock() }; settings.treeBody = newValue }
    }

    static var responseGate: DispatchSemaphore? {
        get { lock.lock(); defer { lock.unlock() }; return settings.responseGate }
        set { lock.lock(); defer { lock.unlock() }; settings.responseGate = newValue }
    }

    static var onResponseWaiting: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return settings.onResponseWaiting }
        set { lock.lock(); defer { lock.unlock() }; settings.onResponseWaiting = newValue }
    }

    static var rejectedTransportError: URLError.Code? {
        get { lock.lock(); defer { lock.unlock() }; return settings.rejectedTransportError }
        set { lock.lock(); defer { lock.unlock() }; settings.rejectedTransportError = newValue }
    }

    static var onBusinessFailure: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return settings.onBusinessFailure }
        set { lock.lock(); defer { lock.unlock() }; settings.onBusinessFailure = newValue }
    }

    static func reset(listenerAvailable: Bool = true) {
        lock.lock()
        recorded = []
        settings = Settings()
        settings.listenerAvailable = listenerAvailable
        lock.unlock()
    }

    static func requests() -> [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url
        Self.lock.lock()
        Self.recorded.append(Recorded(
            host: url?.host,
            port: url?.port,
            path: url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization")
        ))
        let settings = Self.settings
        let rejected = url?.port == settings.rejectPort
        let failBusiness = url?.path != "/ping" && settings.businessFailuresRemaining > 0
        if failBusiness { Self.settings.businessFailuresRemaining -= 1 }
        if rejected { Self.settings.onRejected = nil }
        Self.lock.unlock()

        let respond = { [self] in
            guard settings.listenerAvailable else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            if failBusiness {
                settings.onBusinessFailure?()
                client?.urlProtocol(self, didFailWithError: URLError(settings.businessTransportError))
                return
            }
            if rejected { settings.onRejected?() }
            if rejected, let error = settings.rejectedTransportError {
                client?.urlProtocol(self, didFailWithError: URLError(error))
                return
            }
            let treeBody = url?.path == "/a11y_tree_full" ? settings.treeBody : nil
            let body = rejected ? #"{"unrelated":true}"# : url?.path == "/ping"
                ? #"{"status":"success","result":"pong","protocol_version":2,"bridge_version":"test"}"#
                : treeBody ?? #"{"status":"success"}"#
            let response = HTTPURLResponse(url: url!, statusCode: rejected ? settings.oldStatus : (url?.path == "/ping" ? 200 : settings.businessStatus), httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if let gate = settings.responseGate, url?.path != "/ping" {
            settings.onResponseWaiting?()
            DispatchQueue.global().async {
                _ = gate.wait(timeout: .now() + 10)
                respond()
            }
        } else {
            respond()
        }
    }

    override func stopLoading() {}
}
