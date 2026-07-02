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
    // no-op: no HID session is created, so `type ""` neither pays
    // framework/simulator-set initialisation nor fails against a
    // device that is not booted — the behaviour an agent's
    // `type "$VAR"` with an empty variable relies on.
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

    // MARK: - Daemon bypass for --stdin

    @Test("--stdin sets daemonBypass on both surfaces")
    func stdinTriggersDaemonBypass() throws {
        let top = try Type.parse([
            "--stdin",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
        ])
        let sub = try IOSSimTypeCommand.parse([
            "--stdin",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
        ])
        #expect(top.daemonBypass)
        #expect(sub.daemonBypass)
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