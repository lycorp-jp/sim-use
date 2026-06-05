// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import AndroidBackend
import ArgumentParser
import Foundation
import SimUseCore
import Testing

// Pins the contract between top-level `Button`, `IOSSimButtonCommand`,
// and `AndroidButtonCommand.performPress`. Mirrors `TapForwarderTests`.
@Suite("Button forwarder")
@MainActor
struct ButtonForwarderTests {

    // MARK: - Validation parity

    @Test("Non-positive duration is rejected")
    func nonPositiveDurationRejected() {
        do {
            try IOSSimButtonCommand.validateOptions(duration: 0)
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("Duration must be greater than 0"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("Duration cap rejected")
    func durationCapRejected() {
        do {
            try IOSSimButtonCommand.validateOptions(duration: 11)
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("Duration must not exceed"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    // MARK: - Symmetric forwarder contract

    @Test("AndroidButtonCommand.performPress is callable with the forwarder's argument shape")
    func androidButtonPerformContract() {
        let _: (
            String,
            Int,
            AndroidDeviceController
        ) throws -> Void = AndroidButtonCommand.performPress
    }

    // MARK: - Flag-surface parity

    @Test("ArgumentParser parses both top-level Button and IOSSimButtonCommand with same flags")
    func flagSurfaceParses() throws {
        let argv = [
            "lock",
            "--duration", "2.5",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
            "--json"
        ]
        let topLevel = try Button.parse(argv)
        let subCmd = try IOSSimButtonCommand.parse(argv)

        #expect(topLevel.buttonType == .lock)
        #expect(subCmd.buttonType == .lock)
        #expect(topLevel.duration == 2.5)
        #expect(subCmd.duration == 2.5)
        #expect(topLevel.jsonOutput)
        #expect(subCmd.jsonOutput)
    }

    @Test("Cross-platform-only Android buttons parse on the top-level surface")
    func androidOnlyButtonParses() throws {
        let parsed = try Button.parse([
            "back",
            "--udid", "emulator-5554",
        ])
        #expect(parsed.buttonType == .back)
        #expect(parsed.buttonType.androidKeyCode != nil)
        #expect(parsed.buttonType.iosHidButton == nil)
    }
}