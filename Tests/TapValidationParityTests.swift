// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import ArgumentParser
import Foundation
import SimUseCore
import Testing

// ArgumentParser (1.5.0) does not auto-validate nested option groups —
// each of the three tap surfaces must call the shared group validators
// (`TapTargetingOptions.validate(alias:)` / `TapTimingOptions.validate()`
// / `TapTimingOptions.validateDuration`) explicitly from its own
// `validate()`. A surface that drops a call still parses fine and loses
// validation silently; that is the regression this suite exists to
// catch. The same invalid argv must fail — with the same message — on
// `tap`, `long-press`, and `ios tap`.
@Suite("Tap validation parity across surfaces")
struct TapValidationParityTests {
    private static let udid = ["--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0"]

    /// argv tails every tap surface must reject. `fragment` anchors
    /// which rule fired; an empty fragment means the message text is
    /// pinned only by cross-surface equality (resolver-owned wording).
    private static let rejectedArgvs: [(argv: [String], fragment: String)] = [
        (["@1", "--label", "Foo"], "cannot be combined with --label"),
        (["--label", "a", "--value", "b"], "Use only one of"),
        (["--label", "   "], "--label must not be empty."),
        (["-x", "100"], ""),
        (["--label", "a", "--label-regex", "(["], ""),
        (["--label", "a", "--pre-delay", "11"], "Pre-delay must be between 0 and 10 seconds."),
        (["--label", "a", "--post-delay", "11"], "Post-delay must be between 0 and 10 seconds."),
        (["--label", "a", "--duration", "11"], "--duration must be between 0 and 10 seconds."),
        (["--label", "a", "--wait-timeout=-1"], "--wait-timeout must be non-negative."),
        (["--label", "a", "--wait-timeout", "1", "--poll-interval", "0"], "--poll-interval must be greater than 0"),
        (["--label", "a", "--frame", "minX=abc"], "is not a number"),
        (["--label", "a", "--frame", "banana=1"], "is unknown"),
        (["-x", "1", "-y", "2", "--frame", "minY=1"], "--frame cannot be combined with explicit"),
        (["@1", "--frame", "minY=1"], "cannot be combined with the @N / #N / #N@M alias forms"),
    ]

    /// nil when the argv parses; the rendered parser message otherwise.
    private func failureMessage<C: ParsableCommand>(_ type: C.Type, _ argv: [String]) -> String? {
        do {
            _ = try type.parse(argv)
            return nil
        } catch {
            return type.message(for: error)
        }
    }

    @Test("same invalid argv fails with the same message on every surface")
    func rejectedParityAcrossSurfaces() {
        for (argv, fragment) in Self.rejectedArgvs {
            let full = argv + Self.udid
            let tap = failureMessage(Tap.self, full)
            let longPress = failureMessage(LongPress.self, full)
            let iosTap = failureMessage(IOSSimTapCommand.self, full)

            #expect(tap != nil, "tap accepted invalid argv \(argv)")
            #expect(longPress != nil, "long-press accepted invalid argv \(argv)")
            #expect(iosTap != nil, "ios tap accepted invalid argv \(argv)")
            #expect(tap == longPress, "tap vs long-press message mismatch for \(argv): '\(tap ?? "nil")' vs '\(longPress ?? "nil")'")
            #expect(tap == iosTap, "tap vs ios tap message mismatch for \(argv): '\(tap ?? "nil")' vs '\(iosTap ?? "nil")'")
            if !fragment.isEmpty {
                #expect(tap?.contains(fragment) == true, "message for \(argv) missing '\(fragment)': '\(tap ?? "nil")'")
            }
        }
    }

    @Test("a kitchen-sink valid argv parses on every surface")
    func acceptedParityAcrossSurfaces() {
        // One selector + type filter + frame + full timing block —
        // valid on all three surfaces (mirrors flagSurfaceParses, which
        // pins field values; this pins acceptance stays in sync with
        // the rejection table above).
        let argv = [
            "--label-contains", "foo",
            "--element-type", "Button",
            "--frame", "minY=0.5r",
            "--pre-delay", "0.1", "--post-delay", "0.1",
            "--duration", "0.5",
            "--wait-timeout", "1.0", "--poll-interval", "0.5",
        ] + Self.udid
        #expect(failureMessage(Tap.self, argv) == nil)
        #expect(failureMessage(LongPress.self, argv) == nil)
        #expect(failureMessage(IOSSimTapCommand.self, argv) == nil)
    }
}
