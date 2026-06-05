// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import SimUseCore
@testable import iOSSimBackend
import ArgumentParser
import Foundation
import Testing

// `batch` is iOS-only by design: the runner amortises per-step cost by
// holding one FBSimulatorHID session open across all steps, which has no
// Android equivalent (every Android step round-trips through the bridge
// over `adb forward` and can be issued as standalone `sim-use` calls).
// Before this guard, Android UDIDs reached the daemon spawn path and
// surfaced an iOS-flavoured "Simulator ... not found in set" error that
// implied the device was the problem rather than the command. The guard
// throws an explicit "not supported on Android" CLIError at
// parse/resolve time, mirroring the `key` / `key-sequence` / `key-combo`
// pattern (HIDKeyCommandHelp). CLIError rather than ArgumentParser's
// ValidationError because the latter's message is swallowed by
// `SimUseExecutableCommand.run()`'s catch (no LocalizedError witness).
@Suite("Batch — Android UDIDs are rejected with a clear iOS-only error")
struct BatchAndroidRejectionTests {
    @Test("emulator-NNNN UDID is rejected with the iOS-only message")
    func emulatorPrefixIsRejected() throws {
        var cmd = try IOSSimBatchCommand.parse(["--step", "tap -x 1 -y 1", "--udid", "emulator-5554"])
        #expect(throws: CLIError.self) {
            try cmd.resolveDeferredArguments()
        }
    }

    @Test("error mentions Android and the offending UDID so the user can self-correct")
    func errorMessageStructure() throws {
        var cmd = try IOSSimBatchCommand.parse(["--step", "tap -x 1 -y 1", "--udid", "emulator-5554"])
        do {
            try cmd.resolveDeferredArguments()
            Issue.record("expected CLIError; resolveDeferredArguments succeeded")
        } catch let error as CLIError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("Android"), "must say Android: \(message)")
            #expect(message.contains("emulator-5554"), "must echo the UDID: \(message)")
            #expect(message.contains("`batch`"), "must quote the verb: \(message)")
        }
    }

    @Test("iOS-shaped UUID UDID is not rejected at resolve time")
    func iOSUUIDPassesResolver() throws {
        // Picks a UDID that looks iOS-shaped (8-4-4-4-12 hex). We only assert
        // the resolver doesn't reject it as Android; the daemon path may
        // still complain that no simulator is booted, but that's expected
        // and unrelated to this guard.
        var cmd = try IOSSimBatchCommand.parse([
            "--step", "tap -x 1 -y 1",
            "--udid", "1A2B3C4D-1234-5678-90AB-CDEFCDEFCDEF"
        ])
        #expect(throws: Never.self) {
            try cmd.resolveDeferredArguments()
        }
    }
}