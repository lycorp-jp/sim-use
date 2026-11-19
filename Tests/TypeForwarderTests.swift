// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import AndroidBackend
import ArgumentParser
import Foundation
import SimUseCore
import Testing

// Pins the contract between top-level `Type`, `IOSSimTypeCommand`,
// and `AndroidTypeCommand`. Mirrors `TapForwarderTests`.
@Suite("Type forwarder")
@MainActor
struct TypeForwarderTests {

    @Test("An unsupported HID character stays out of the diagnostic")
    func privateHIDError() {
        do {
            _ = try TextToHIDEvents.convertTextToHIDEvents("TestMarker猫")
            Issue.record("Expected unsupported text to fail")
        } catch {
            #expect(!error.localizedDescription.contains("猫"))
            #expect(error.localizedDescription.contains("keyboard"))
        }
    }

    @Test("Debug output and JSON errors keep stdin text private")
    func debugOutputOmitsInput() async throws {
        let binary = try TestHelpers.getSimUsePath()
        let marker = "PrivateMarker猫"
        let result = try await CommandRunner.run(
            "printf '%s' '\(marker)' | SIM_USE_DEBUG=1 SIM_USE_NO_DAEMON=1 '\(binary)' ios type --stdin --json --device 00000000-DEAD-BEEF-0000-000000000000",
            allowFailure: true
        )
        #expect(result.exitCode != 0)
        #expect(result.output.contains("keyboard"))
        #expect(!result.output.contains("PrivateMarker"))
        #expect(!result.output.contains("猫"))
    }

    // MARK: - Validation parity

    @Test("Multiple input sources are rejected")
    func multipleSourcesRejected() {
        do {
            try IOSSimTypeCommand.validateOptions(text: "hi", useStdin: true, inputFile: nil)
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("only one input source"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("Missing input source is rejected")
    func missingSourceRejected() {
        do {
            try IOSSimTypeCommand.validateOptions(text: nil, useStdin: false, inputFile: nil)
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("No input provided"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("Single positional source passes validation")
    func positionalPasses() throws {
        try IOSSimTypeCommand.validateOptions(text: "hello", useStdin: false, inputFile: nil)
    }

    // MARK: - Empty input short-circuit

    // Empty input produces zero HID events and must stay a strict
    // no-op: it returns before the framework preflight (Xcode check,
    // private-framework load) and never creates a HID session, so
    // `type ""` neither pays initialisation nor fails against a device
    // that is not booted — the behaviour an agent's `type "$VAR"` with
    // an empty variable relies on. Keeping the preflight out of this
    // path is also what keeps the test independent of the host's
    // Xcode state (the `xcode-select` subprocess flaked on CI).
    @Test("Empty input succeeds without touching the HID session path")
    func emptyInputShortCircuits() async throws {
        // iOS-shaped UDID that matches no simulator on this host:
        // reaching makeSession would throw "not found in set".
        var cmd = try IOSSimTypeCommand.parse([
            "", "--udid", "00000000-DEAD-BEEF-0000-000000000000",
        ])
        try cmd.resolveDeferredArguments()
        _ = try await cmd.execute()
    }

    // MARK: - Symmetric forwarder contract

    @Test("AndroidTypeCommand.performType is callable with the forwarder's argument shape")
    func androidTypePerformContract() {
        let _: (
            String,
            String,
            Bool,
            AndroidDeviceController
        ) throws -> Void = AndroidTypeCommand.performType
    }

    // MARK: - Caller-side input is inlined for the daemon

    // On the CoreDevice (dtuhidd) HID transport a short-lived process
    // exits before dtuhidd activates its connection, so `--stdin` must go
    // through the daemon like every other input (see DaemonInlineInput).
    @Test("--stdin does not bypass the daemon on either surface")
    func stdinGoesThroughDaemon() throws {
        let top = try Type.parse([
            "--stdin",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
        ])
        let sub = try IOSSimTypeCommand.parse([
            "--stdin",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
        ])
        #expect(top.daemonBypass == false)
        #expect(sub.daemonBypass == false)
    }

    @Test("--file is read in the client and forwarded as the positional on both surfaces")
    func fileIsInlined() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("type-forward-\(UUID().uuidString).txt").path
        try "-5 apples\nline 2\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let udid = "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0"

        let topArgv = ["type", "--file", path, "--device", udid]
        let top = try Type.parse(Array(topArgv.dropFirst()))
        let topForwarded = try top.daemonArguments(from: topArgv)
        #expect(topForwarded == ["type", "--device", udid, "--", "-5 apples\nline 2\n"])
        let topDaemonSide = try Type.parse(Array(topForwarded.dropFirst()))
        #expect(topDaemonSide.text == "-5 apples\nline 2\n")
        #expect(topDaemonSide.inputFile == nil)

        let subArgv = ["ios", "type", "--file", path, "--device", udid]
        let sub = try IOSSimTypeCommand.parse(Array(subArgv.dropFirst(2)))
        let subForwarded = try sub.daemonArguments(from: subArgv)
        #expect(subForwarded == ["ios", "type", "--device", udid, "--", "-5 apples\nline 2\n"])
        #expect(try IOSSimTypeCommand.parse(Array(subForwarded.dropFirst(2))).text == "-5 apples\nline 2\n")
    }

    @Test("Positional text is forwarded unchanged")
    func positionalIsUnchanged() throws {
        let argv = ["type", "hello", "--device", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0"]
        let top = try Type.parse(Array(argv.dropFirst()))
        #expect(try top.daemonArguments(from: argv) == argv)
    }

    @Test("Positional text does not set daemonBypass")
    func positionalDoesNotBypassDaemon() throws {
        let top = try Type.parse([
            "hello",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
        ])
        let sub = try IOSSimTypeCommand.parse([
            "hello",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
        ])
        #expect(top.daemonBypass == false)
        #expect(sub.daemonBypass == false)
    }

    // MARK: - Flag-surface parity

    @Test("ArgumentParser parses both top-level Type and IOSSimTypeCommand with same flags")
    func flagSurfaceParses() throws {
        let argv = [
            "Hello, world!",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
            "--json"
        ]
        let topLevel = try Type.parse(argv)
        let subCmd = try IOSSimTypeCommand.parse(argv)

        #expect(topLevel.text == "Hello, world!")
        #expect(subCmd.text == "Hello, world!")
        #expect(topLevel.jsonOutput)
        #expect(subCmd.jsonOutput)
    }
}