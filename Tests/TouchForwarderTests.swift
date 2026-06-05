// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import AndroidBackend
import ArgumentParser
import Foundation
import SimUseCore
import Testing

// Pins the contract between top-level `Touch`, `IOSSimTouchCommand`,
// and `AndroidTouchCommand`. Mirrors `TapForwarderTests`.
@Suite("Touch forwarder")
@MainActor
struct TouchForwarderTests {

    // MARK: - Validation parity

    @Test("Negative coordinates rejected")
    func negativeCoordsRejected() {
        do {
            try IOSSimTouchCommand.validateOptions(
                pointX: -1, pointY: 0,
                touchDown: true, touchUp: true,
                delay: nil
            )
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("non-negative"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("Neither --down nor --up rejected")
    func neitherActionRejected() {
        do {
            try IOSSimTouchCommand.validateOptions(
                pointX: 0, pointY: 0,
                touchDown: false, touchUp: false,
                delay: nil
            )
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("At least one of --down or --up"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("Delay without both --down and --up rejected")
    func delayRequiresBothActions() {
        do {
            try IOSSimTouchCommand.validateOptions(
                pointX: 0, pointY: 0,
                touchDown: true, touchUp: false,
                delay: 0.5
            )
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("Delay can only be used when both"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    // MARK: - Android split-form redirect

    @Test("Split form on Android produces standard redirect")
    func splitFormRedirectIncludesAtomicHint() {
        let msg = AndroidTouchCommand.splitFormRedirect(
            x: 100.7, y: 200.3, udid: "emulator-5554"
        )
        // Coords round to nearest pixel — not truncate-toward-zero —
        // so a user typing `--x 100.7` sees `101`, not `100`.
        #expect(msg.contains("--x 101"))
        #expect(msg.contains("--y 200"))
        #expect(msg.contains("--down --up"))
        #expect(msg.contains("emulator-5554"))
    }

    // MARK: - Symmetric forwarder contract

    @Test("AndroidTouchCommand.performTouch is callable with the forwarder's argument shape")
    func androidTouchPerformContract() {
        let _: (
            String,
            Double, Double,
            Double?,
            AndroidDeviceController
        ) throws -> Void = AndroidTouchCommand.performTouch
    }

    // MARK: - Flag-surface parity

    @Test("ArgumentParser parses both top-level Touch and IOSSimTouchCommand with same flags")
    func flagSurfaceParses() throws {
        let argv = [
            "--x", "100",
            "--y", "200",
            "--down",
            "--up",
            "--delay", "0.5",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
            "--json"
        ]
        let topLevel = try Touch.parse(argv)
        let subCmd = try IOSSimTouchCommand.parse(argv)

        #expect(topLevel.pointX == 100)
        #expect(subCmd.pointX == 100)
        #expect(topLevel.touchDown && topLevel.touchUp)
        #expect(subCmd.touchDown && subCmd.touchUp)
        #expect(topLevel.delay == 0.5)
        #expect(subCmd.delay == 0.5)
        #expect(topLevel.jsonOutput)
        #expect(subCmd.jsonOutput)
    }
}