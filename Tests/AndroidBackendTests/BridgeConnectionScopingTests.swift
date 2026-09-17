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

    /// Session written against server A, client now pointed at server B:
    /// the cached port and token must not be used, even though a
    /// listener answers on B at A's old port.
    func testSwitchingAdbServerRecreatesForwardAndToken() throws {
        persistSession(token: "token-A", localPort: 18080, environment: serverA)

        try makeClient(environment: serverB).pressKey(3)

        assertNothingSent(toPort: 18080, withToken: "token-A")
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

    /// The fast path survives: same connection and the forward is still
    /// registered for this serial, so no adb bootstrap is repeated.
    func testMatchingSessionWithLiveForwardIsReused() throws {
        persistSession(token: "token-A", localPort: 18080, environment: serverA)
        try "\(serial) tcp:18080 tcp:8080\n".write(to: forwardList, atomically: true, encoding: .utf8)

        try makeClient(environment: serverA).pressKey(3)

        assertAllRequests(host: "192.0.2.10", port: 18080, authorizedWith: "token-A")
        XCTAssertFalse(adbCalls().contains { $0.contains("forward tcp:0") }, "no new forward expected")
        XCTAssertFalse(adbCalls().contains { $0.contains("content query") }, "no token fetch expected")
    }

    /// The rewritten session records the connection it was created for.
    func testRecreatedSessionRecordsItsConnection() throws {
        persistSession(token: "token-A", localPort: 18080, environment: serverA)

        try makeClient(environment: serverB).pressKey(3)

        let stored = try XCTUnwrap(BridgeSessionStore.read(udid: serial, home: home))
        XCTAssertEqual(stored.localPort, 18081)
        XCTAssertEqual(stored.token, "token-B")
        XCTAssertEqual(stored.connection, BridgeConnection(environment: serverB).identity)
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

    // MARK: - Fixtures

    private func persistSession(token: String, localPort: Int, environment: [String: String]) {
        let session = BridgeSession(
            token: token,
            localPort: localPort,
            remotePort: BridgeClient.defaultRemotePort,
            connection: BridgeConnection(environment: environment).identity
        )
        BridgeSessionStore.write(session, udid: serial, home: home)
    }

    private func makeClient(environment: [String: String]) throws -> BridgeClient {
        let script = root.appendingPathComponent("adb")
        let body = """
            #!/bin/sh
            echo "$*" >> '\(adbLog.path)'
            case "$*" in
              *"forward --list"*) \(failForwardList ? "echo 'error: cannot connect to daemon' >&2; exit 1" : "cat '\(forwardList.path)' 2>/dev/null") ;;
              *"forward tcp:0 tcp:8080"*) echo 18081 ;;
              *"content query"*) echo "Row: 0 result=token-B" ;;
            esac
            exit 0

            """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

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

/// Answers every bridge request successfully — whatever host or port it
/// was addressed to — and records where it went.
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

    static func reset() {
        lock.lock(); recorded = []; lock.unlock()
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
        Self.lock.unlock()

        let body = url?.path == "/ping"
            ? #"{"status":"success","result":"pong","protocol_version":2,"bridge_version":"test"}"#
            : #"{"status":"success"}"#
        let response = HTTPURLResponse(url: url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
