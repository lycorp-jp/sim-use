// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import AndroidBackend
import ArgumentParser
import Foundation
import SimUseCore
import Testing

// Pins the contract between top-level `KeyboardState`,
// `IOSSimKeyboardStateCommand`, and `AndroidKeyboardStateCommand`.
@Suite("KeyboardState forwarder")
@MainActor
struct KeyboardStateForwarderTests {

    // MARK: - Symmetric forwarder contract

    @Test("AndroidKeyboardStateCommand.performKeyboardState is callable with the forwarder's argument shape")
    func androidKeyboardStatePerformContract() {
        let _: (
            String,
            AndroidDeviceController
        ) throws -> KeyboardStateResult = AndroidKeyboardStateCommand.performKeyboardState
    }

    // MARK: - ExecutionResult symbol parity

    @Test("Top-level KeyboardState.ExecutionResult is the IOSSim type")
    func executionResultTypealias() {
        // Compile-time pin: the typealias must keep
        // `KeyboardState.ExecutionResult` pointing at the iOS sub's
        // struct so the existing `KeyboardStateExecutionResultTests`
        // (which constructs `KeyboardState.ExecutionResult`) keep
        // compiling.
        let direct = IOSSimKeyboardStateCommand.ExecutionResult(
            platform: "ios", visible: true,
            chromeKeyCount: 1, letterKeyCount: 2, idChromeCount: 3, globeSeen: true
        )
        let aliased: KeyboardState.ExecutionResult = direct
        #expect(aliased.platform == "ios")
        #expect(aliased.visible)
    }

    // MARK: - Flag-surface parity

    @Test("ArgumentParser parses both top-level KeyboardState and IOSSimKeyboardStateCommand with same flags")
    func flagSurfaceParses() throws {
        let argv = [
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
            "--json",
        ]
        let topLevel = try KeyboardState.parse(argv)
        let subCmd = try IOSSimKeyboardStateCommand.parse(argv)
        #expect(topLevel.jsonOutput)
        #expect(subCmd.jsonOutput)
    }
}