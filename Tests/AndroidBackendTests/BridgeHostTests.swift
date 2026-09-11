// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import AndroidBackend

/// `adb forward` listens on the machine running the adb server, so the
/// bridge host follows `ADB_SERVER_SOCKET` when that server is remote
/// (e.g. WSL talking to the Windows host's adb), with
/// `SIM_USE_BRIDGE_HOST` as an explicit override.
@Suite("BridgeClient.resolveBridgeHost")
struct BridgeHostTests {
    @Test("No adb server override → loopback")
    func defaultIsLoopback() {
        #expect(BridgeClient.resolveBridgeHost(environment: [:]) == "127.0.0.1")
    }

    @Test("Local adb server sockets stay on loopback", arguments: [
        "tcp:5037",
        "tcp:localhost:5037",
        "tcp:127.0.0.1:5037",
        "tcp:[::1]:5037",
        "localfilesystem:/tmp/adb.sock",
        "",
    ])
    func localServerIsLoopback(socket: String) {
        #expect(BridgeClient.resolveBridgeHost(environment: ["ADB_SERVER_SOCKET": socket]) == "127.0.0.1")
    }

    @Test("Remote adb server → its host")
    func remoteServerHost() {
        let env = ["ADB_SERVER_SOCKET": "tcp:172.20.64.1:5037"]
        #expect(BridgeClient.resolveBridgeHost(environment: env) == "172.20.64.1")
    }

    @Test("Remote IPv6 adb server keeps its brackets")
    func remoteIPv6ServerHost() {
        let env = ["ADB_SERVER_SOCKET": "tcp:[fd00::1]:5037"]
        #expect(BridgeClient.resolveBridgeHost(environment: env) == "[fd00::1]")
    }

    @Test("SIM_USE_BRIDGE_HOST wins over ADB_SERVER_SOCKET")
    func explicitOverrideWins() {
        let env = ["SIM_USE_BRIDGE_HOST": "10.0.0.7", "ADB_SERVER_SOCKET": "tcp:172.20.64.1:5037"]
        #expect(BridgeClient.resolveBridgeHost(environment: env) == "10.0.0.7")
    }

    @Test("A bare IPv6 override is bracketed")
    func bareIPv6OverrideIsBracketed() {
        #expect(BridgeClient.resolveBridgeHost(environment: ["SIM_USE_BRIDGE_HOST": "fd00::7"]) == "[fd00::7]")
    }

    @Test("Every resolved host forms a valid bridge URL", arguments: [
        ["ADB_SERVER_SOCKET": "tcp:172.20.64.1:5037"],
        ["ADB_SERVER_SOCKET": "tcp:[fd00::1]:5037"],
        ["ADB_SERVER_SOCKET": "tcp:[fe80::1%eth0]:5037"],
        ["SIM_USE_BRIDGE_HOST": "fe80::1%eth0"],
    ])
    func resolvedHostFormsURL(environment: [String: String]) {
        let host = BridgeClient.resolveBridgeHost(environment: environment)
        #expect(URL(string: "http://\(host):8080/ping") != nil, "host \(host)")
    }
}
