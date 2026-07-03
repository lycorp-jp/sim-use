// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import Foundation
import Testing
@testable import SimUseCore

// Shared stable-order encoder so assertions can match exact JSON bytes.
private func encoderStable() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}

private func jsonString(_ data: Data) -> String {
    String(data: data, encoding: .utf8) ?? ""
}

// MARK: - DaemonRequest

@Suite("DaemonRequest codable")
struct DaemonRequestCodableTests {
    @Test("Encoding omits id when nil; cmd and args are present")
    func encodeOmitsNilId() throws {
        let req = DaemonRequest(cmd: "describe-ui", args: ["--udid", "abc"])
        let text = jsonString(try encoderStable().encode(req))
        #expect(text == #"{"args":["--udid","abc"],"cmd":"describe-ui"}"#)
    }

    @Test("Encoding includes id when set")
    func encodeWithId() throws {
        let req = DaemonRequest(id: "trace-1", cmd: "tap", args: [])
        let text = jsonString(try encoderStable().encode(req))
        #expect(text == #"{"args":[],"cmd":"tap","id":"trace-1"}"#)
    }

    @Test("Round-trip preserves fields")
    func roundTrip() throws {
        let req = DaemonRequest(id: "c0", cmd: "swipe", args: ["--from", "1,2", "--to", "3,4"])
        let encoded = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(DaemonRequest.self, from: encoded)
        #expect(decoded.id == "c0")
        #expect(decoded.cmd == "swipe")
        #expect(decoded.args == ["--from", "1,2", "--to", "3,4"])
    }

    @Test("Absent args on the wire decode as empty, not an error")
    func absentArgsDefaultsEmpty() throws {
        let wire = Data(#"{"cmd":"_ping"}"#.utf8)
        let decoded = try JSONDecoder().decode(DaemonRequest.self, from: wire)
        #expect(decoded.cmd == "_ping")
        #expect(decoded.args == [])
        #expect(decoded.id == nil)
    }
}

// MARK: - DaemonErrorResponse

@Suite("DaemonErrorResponse encoding")
struct DaemonErrorResponseTests {
    @Test("Omits hint when nil; emits ok=false, kind raw value")
    func hintOmittedWhenNil() throws {
        let resp = DaemonErrorResponse(error: "bad input", kind: .permanent)
        let text = jsonString(try encoderStable().encode(resp))
        #expect(text == #"{"error":"bad input","kind":"permanent","ok":false}"#)
    }

    @Test("Emits hint when present")
    func hintEmittedWhenPresent() throws {
        let resp = DaemonErrorResponse(
            error: "simulator booting",
            kind: .transientBooting,
            hint: "wait and retry"
        )
        let text = jsonString(try encoderStable().encode(resp))
        #expect(text == #"{"error":"simulator booting","hint":"wait and retry","kind":"transient_booting","ok":false}"#)
    }

    @Test("Includes id when the request carried one")
    func withId() throws {
        let resp = DaemonErrorResponse(id: "c42", error: "nope", kind: .other)
        let text = jsonString(try encoderStable().encode(resp))
        #expect(text == #"{"error":"nope","id":"c42","kind":"other","ok":false}"#)
    }
}

// MARK: - DaemonSuccessResponse

@Suite("DaemonSuccessResponse encoding")
struct DaemonSuccessResponseTests {
    private struct Payload: Encodable {
        let foo: String
        let count: Int
    }

    @Test("Payload nests under data; id omitted when nil; ok=true")
    func nestedDataNoId() throws {
        let resp = DaemonSuccessResponse(data: Payload(foo: "bar", count: 3))
        let text = jsonString(try encoderStable().encode(resp))
        #expect(text == #"{"data":{"count":3,"foo":"bar"},"ok":true}"#)
    }

    @Test("Includes id when set")
    func withId() throws {
        let resp = DaemonSuccessResponse(id: "c1", data: Payload(foo: "x", count: 0))
        let text = jsonString(try encoderStable().encode(resp))
        #expect(text == #"{"data":{"count":0,"foo":"x"},"id":"c1","ok":true}"#)
    }

    @Test("Advisory is omitted from the envelope when nil")
    func advisoryOmittedWhenNil() throws {
        let resp = DaemonSuccessResponse(data: Payload(foo: "bar", count: 3), advisory: nil)
        let text = jsonString(try encoderStable().encode(resp))
        #expect(text == #"{"data":{"count":3,"foo":"bar"},"ok":true}"#)
    }

    @Test("Advisory nests under the process key when present")
    func advisoryNestsUnderProcess() throws {
        let event = ProcessEvent(kind: .disappeared, bundleId: "com.x", pid: 100, confidence: .high)
        let resp = DaemonSuccessResponse(
            data: Payload(foo: "bar", count: 3),
            advisory: ProcessAdvisory(events: [event], pending: [])
        )
        let text = jsonString(try encoderStable().encode(resp))
        #expect(text == #"{"data":{"count":3,"foo":"bar"},"ok":true,"process":{"events":[{"bundleId":"com.x","confidence":"high","kind":"disappeared","pid":100}],"pending":[]}}"#)
    }

    @Test("Command advisory nests under the advisory key when present")
    func commandAdvisoryNestsUnderAdvisory() throws {
        let resp = DaemonSuccessResponse(
            data: Payload(foo: "bar", count: 3),
            commandAdvisory: CommandAdvisory(kind: .fullScreenTapTarget, message: "check target")
        )
        let text = jsonString(try encoderStable().encode(resp))
        #expect(text == #"{"advisory":{"kind":"full_screen_tap_target","message":"check target"},"data":{"count":3,"foo":"bar"},"ok":true}"#)
    }
}

// MARK: - DaemonPingData

@Suite("DaemonPingData codable round-trip")
struct DaemonPingDataTests {
    @Test("Round-trip preserves every field verbatim")
    func roundTrip() throws {
        let ping = DaemonPingData(
            pid: 4242,
            uptimeSeconds: 123.5,
            protocolVersion: DaemonProtocol.version,
            simUseVersion: "1.7.0-rc",
            udid: "ABCD-1234"
        )
        let data = try JSONEncoder().encode(ping)
        let decoded = try JSONDecoder().decode(DaemonPingData.self, from: data)
        #expect(decoded.pid == 4242)
        #expect(decoded.uptimeSeconds == 123.5)
        #expect(decoded.protocolVersion == DaemonProtocol.version)
        #expect(decoded.simUseVersion == "1.7.0-rc")
        #expect(decoded.udid == "ABCD-1234")
    }
}

// MARK: - ManagementCommand

@Suite("DaemonProtocol.ManagementCommand")
struct ManagementCommandTests {
    @Test("Raw values match the reserved wire names")
    func rawMapping() {
        #expect(DaemonProtocol.ManagementCommand(rawValue: "_ping") == .ping)
        #expect(DaemonProtocol.ManagementCommand(rawValue: "_stop") == .stop)
    }

    @Test("Regular command names are not management")
    func regularCommandsRejected() {
        #expect(DaemonProtocol.ManagementCommand(rawValue: "describe-ui") == nil)
        #expect(DaemonProtocol.ManagementCommand(rawValue: "ping") == nil) // no underscore
        #expect(DaemonProtocol.ManagementCommand(rawValue: "") == nil)
    }
}

// MARK: - Protocol version

@Suite("DaemonProtocol.version")
struct DaemonProtocolVersionTests {
    @Test("Version is a positive integer")
    func positive() {
        #expect(DaemonProtocol.version >= 1)
    }
}

// MARK: - daemon stop --json entry (device-id key Phase 2)

@Suite("Daemon.Stop.StopEntry codable")
struct DaemonStopEntryCodableTests {
    @Test("Encoding emits deviceId and omits the legacy udid key")
    func encodeEmitsDeviceIdOnly() throws {
        let entry = Daemon.Stop.StopEntry(
            udid: "UDID-1", pid: 42, method: "stop", stopped: true, error: nil
        )
        let text = jsonString(try encoderStable().encode(entry))
        #expect(text == #"{"deviceId":"UDID-1","method":"stop","pid":42,"stopped":true}"#)
        #expect(!text.contains(#""udid""#))
    }

    @Test("Decoding accepts legacy udid-only payloads")
    func decodeLegacyUDIDOnly() throws {
        let payload = #"{"udid":"legacy","pid":7,"method":"sigterm","stopped":false,"error":"boom"}"#
        let entry = try JSONDecoder().decode(Daemon.Stop.StopEntry.self, from: Data(payload.utf8))
        #expect(entry.udid == "legacy")
        #expect(entry.pid == 7)
        #expect(entry.method == "sigterm")
        #expect(entry.stopped == false)
        #expect(entry.error == "boom")
    }

    @Test("Decoding prefers deviceId when both keys are present")
    func decodePrefersDeviceId() throws {
        let payload = #"{"deviceId":"new","udid":"old","pid":1,"method":"none","stopped":true}"#
        let entry = try JSONDecoder().decode(Daemon.Stop.StopEntry.self, from: Data(payload.utf8))
        #expect(entry.udid == "new")
    }
}

// MARK: - daemon status --json entry (device-id key Phase 2)

@Suite("Daemon.Status.StatusEntry codable")
struct DaemonStatusEntryCodableTests {
    @Test("Encoding emits deviceId and omits the legacy udid key")
    func encodeEmitsDeviceIdOnly() throws {
        let entry = Daemon.Status.StatusEntry(
            udid: "UDID-9",
            pid: 9,
            uptimeSeconds: 12.5,
            simUseVersion: "1.0.0",
            protocolVersion: 3,
            socketPath: "/s",
            logPath: "/l",
            reachable: true,
            error: nil
        )
        let text = jsonString(try encoderStable().encode(entry))
        #expect(text == #"{"deviceId":"UDID-9","logPath":"/l","pid":9,"protocolVersion":3,"reachable":true,"simUseVersion":"1.0.0","socketPath":"/s","uptimeSeconds":12.5}"#)
        #expect(!text.contains(#""udid""#))
    }

    @Test("Decoding accepts legacy udid-only payloads")
    func decodeLegacyUDIDOnly() throws {
        let payload = #"""
        {"udid":"legacy","pid":3,"uptimeSeconds":0,"simUseVersion":"","protocolVersion":0,
         "socketPath":"/sock","logPath":"/log","reachable":false,"error":"unreachable"}
        """#
        let entry = try JSONDecoder().decode(Daemon.Status.StatusEntry.self, from: Data(payload.utf8))
        #expect(entry.udid == "legacy")
        #expect(entry.reachable == false)
        #expect(entry.error == "unreachable")
    }

    @Test("Decoding prefers deviceId when both keys are present")
    func decodePrefersDeviceId() throws {
        let payload = #"""
        {"deviceId":"new","udid":"old","pid":3,"uptimeSeconds":1,"simUseVersion":"v",
         "protocolVersion":1,"socketPath":"/sock","logPath":"/log","reachable":true}
        """#
        let entry = try JSONDecoder().decode(Daemon.Status.StatusEntry.self, from: Data(payload.utf8))
        #expect(entry.udid == "new")
    }
}
