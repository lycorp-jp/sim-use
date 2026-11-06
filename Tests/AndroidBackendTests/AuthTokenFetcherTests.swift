// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import AndroidBackend

final class AuthTokenFetcherTests: XCTestCase {

    func testParsesJSONResultColumn() {
        let stdout = """
        Row: 0 result={"status":"success","result":"abc-def-ghi"}
        """
        XCTAssertEqual(AuthTokenFetcher.parse(stdout: stdout), "abc-def-ghi")
    }

    func testParsesRawColumnFallback() {
        let stdout = "Row: 0 result=raw-uuid-without-json"
        XCTAssertEqual(AuthTokenFetcher.parse(stdout: stdout), "raw-uuid-without-json")
    }

    func testReturnsNilWhenMissing() {
        XCTAssertNil(AuthTokenFetcher.parse(stdout: "No result found."))
        XCTAssertNil(AuthTokenFetcher.parse(stdout: ""))
    }

    func testEndpointPortsAndLegacyDefault() throws {
        for port in [8080, 49152, 49159] {
            let endpoint = try XCTUnwrap(AuthTokenFetcher.parseEndpoint(
                stdout: "Row: 0 result={\"result\":\"token\",\"port\":\(port)}"))
            XCTAssertEqual(endpoint.remotePort, port)
        }
        XCTAssertEqual(try AuthTokenFetcher.parseEndpoint(
            stdout: #"Row: 0 result={"result":"token"}"#)?.remotePort, 8080)
    }

    func testEndpointExhaustionFailsBeforeHTTP() {
        XCTAssertThrowsError(try AuthTokenFetcher.parseEndpoint(
            stdout: #"Row: 0 result={"result":"token","server_error":"Bridge ports are occupied; inspect adb shell ss -ltnp"}"#)) { error in
            XCTAssertTrue(error.localizedDescription.contains("ports are occupied"))
        }
        XCTAssertThrowsError(try AuthTokenFetcher.parseEndpoint(
            stdout: #"Row: 0 result={"result":"token","port":0}"#))
    }

    func testExplicitUnavailableStateNeverDefaultsToLegacyPort() {
        for state in ["starting", "stopped", "failed", "running"] {
            XCTAssertThrowsError(try AuthTokenFetcher.parseEndpoint(
                stdout: "Row: 0 result={\"result\":\"token\",\"server_state\":\"\(state)\"}"))
        }
    }

    func testUnavailableEndpointErrorCarriesDeviceAndRecoveryHint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("adb")
        try """
        #!/bin/sh
        echo 'Row: 0 result={"result":"token","server_state":"stopped"}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        XCTAssertThrowsError(try AuthTokenFetcher.fetchEndpoint(adb: Adb(binaryPath: script.path), serial: "test-target")) {
            guard let error = $0 as? BridgeError,
                  case .transport(_, let serial) = error else { return XCTFail("Expected transport error") }
            XCTAssertEqual(serial, "test-target")
            XCTAssertNotNil(error.hint)
        }
    }

    func testInitializationPollsUntilRunningFailureOrSoftBudget() throws {
        for terminal in ["running", "failed", "stopped", "starting", "legacy"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let script = root.appendingPathComponent("adb")
            let count = root.appendingPathComponent("queries")
            let first = root.appendingPathComponent("first")
            let finalJSON: String
            switch terminal {
            case "running": finalJSON = #"{"result":"token","server_state":"running","port":49153}"#
            case "legacy": finalJSON = #"{"result":"token"}"#
            case "failed": finalJSON = #"{"result":"token","server_state":"failed","server_error":"ports occupied"}"#
            default: finalJSON = "{\"result\":\"token\",\"server_state\":\"\(terminal)\"}"
            }
            try """
            #!/bin/sh
            echo query >> '\(count.path)'
            if [ ! -f '\(first.path)' ]; then
              touch '\(first.path)'
              echo 'Row: 0 result={"result":"token","server_state":"stopped"}'
            else
              echo 'Row: 0 result=\(finalJSON)'
            fi
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let adb = Adb(binaryPath: script.path)
            if terminal == "running" || terminal == "legacy" {
                let endpoint = try AuthTokenFetcher.fetchEndpoint(
                    adb: adb, serial: "test-target", timeout: 0.2, pollInterval: 0.01)
                XCTAssertEqual(endpoint.remotePort, terminal == "running" ? 49153 : 8080)
            } else {
                XCTAssertThrowsError(try AuthTokenFetcher.fetchEndpoint(
                    adb: adb, serial: "test-target", timeout: 0.1, pollInterval: 0.01)) {
                    guard let error = $0 as? BridgeError,
                          case .transport(_, let serial) = error else { return XCTFail("Expected transport error") }
                    XCTAssertEqual(serial, "test-target")
                    XCTAssertNotNil(error.hint)
                }
            }
            let queries = try String(contentsOf: count, encoding: .utf8).split(separator: "\n").count
            if terminal == "failed" { XCTAssertEqual(queries, 2) }
            else if terminal == "running" || terminal == "legacy" { XCTAssertEqual(queries, 2) }
            else { XCTAssertGreaterThan(queries, 1); XCTAssertLessThan(queries, 30) }
        }
    }

    func testSlowProviderQueriesUseIndependentCommandTimeout() throws {
        for state in ["running", "stopped"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let script = root.appendingPathComponent("adb")
            let queries = root.appendingPathComponent("queries")
            try """
            #!/bin/sh
            echo query >> '\(queries.path)'
            sleep 0.2
            echo 'Row: 0 result={"result":"token","server_state":"\(state)","port":49153}'
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let start = ContinuousClock.now
            let adb = Adb(binaryPath: script.path, defaultTimeout: 2)
            if state == "running" {
                let endpoint = try AuthTokenFetcher.fetchEndpoint(
                    adb: adb, serial: "test-target", timeout: 0.05, pollInterval: 0.01)
                XCTAssertEqual(endpoint.remotePort, 49153)
            } else {
                XCTAssertThrowsError(try AuthTokenFetcher.fetchEndpoint(
                    adb: adb, serial: "test-target", timeout: 0.05, pollInterval: 0.01)) {
                    guard case BridgeError.transport(let message, _) = $0 else { return XCTFail("Expected polling timeout") }
                    XCTAssertTrue(message.contains("timed out waiting for startup"))
                }
            }
            XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(150))
            XCTAssertEqual(try String(contentsOf: queries, encoding: .utf8).split(separator: "\n").count, 1)
        }
    }

    // MARK: - classifyBridgeMissing

    /// The provider-absent signal travels two distinct paths:
    /// stdout when `content query` happens to exit 0 with the
    /// platform's terse "No result found." line, and stderr when
    /// the activity manager refuses the call with "Error while
    /// accessing provider" / "Unknown URL". Both must funnel into
    /// `BridgeError.bridgeNotInstalled` so the user sees the
    /// actionable "run `sim-use android init`" hint instead of a
    /// raw `adb` failure dump.
    func testClassifyBridgeMissingOnNoResultFound() {
        XCTAssertTrue(AuthTokenFetcher.outputIndicatesBridgeMissing("No result found."))
    }

    func testClassifyBridgeMissingOnUnknownUri() {
        let stderr = """
        java.lang.IllegalArgumentException: Unknown URL content://com.linecorp.simuse.devicebridge/auth_token
            at android.content.ContentResolver.acquireProvider(ContentResolver.java:1234)
        """
        XCTAssertTrue(AuthTokenFetcher.outputIndicatesBridgeMissing(stderr))
    }

    func testClassifyBridgeMissingOnAccessingProviderError() {
        let stderr = "Error while accessing provider:com.linecorp.simuse.devicebridge\nat android.content.ContentResolver..."
        XCTAssertTrue(AuthTokenFetcher.outputIndicatesBridgeMissing(stderr))
    }

    func testClassifyReturnsFalseForUnrelatedOutput() {
        XCTAssertFalse(AuthTokenFetcher.outputIndicatesBridgeMissing(""))
        XCTAssertFalse(AuthTokenFetcher.outputIndicatesBridgeMissing("Row: 0 result=ok"))
        XCTAssertFalse(AuthTokenFetcher.outputIndicatesBridgeMissing("permission denied"))
    }
}