// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import AndroidBackend
import ArgumentParser
import Foundation
import SimUseCore
import Testing

// Pins the contract between the top-level `Tap` and the
// `IOSSimTapCommand` it forwards to:
//
//   * Both surfaces validate input through the shared group validators
//     (`TapTargetingOptions.validate(alias:)` /
//     `TapTimingOptions.validate()`). Cross-surface message equality is
//     pinned by `TapValidationParityTests`; the cases below pin the
//     rules themselves at the group level.
//   * `PlatformRouter.resolve(udid:)` is what picks the branch in
//     `Tap.execute()`. The test cases below cover the two real-world
//     UDID shapes plus the empty / typo case (defers to iOS so the
//     "not booted" error surfaces fast).
//
// Locks the Step-4 migration so future refactors can't silently drop
// validation parity or reverse the platform routing.
@Suite("Tap forwarder")
@MainActor
struct TapForwarderTests {

    // MARK: - Platform routing decision

    @Test("iOS Simulator UDID routes to iOSSim")
    func iosUdidRoutesToIOSSim() {
        let udid = "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0"
        #expect(PlatformRouter.resolve(udid: udid) == .iOSSim)
        #expect(PlatformRouter.looksLikeAndroid(udid) == false)
    }

    @Test("Android emulator serial routes to android")
    func emulatorUdidRoutesToAndroid() {
        let udid = "emulator-5554"
        #expect(PlatformRouter.resolve(udid: udid) == .android)
        #expect(PlatformRouter.looksLikeAndroid(udid))
    }

    @Test("Adb device serial routes to android")
    func realDeviceSerialRoutesToAndroid() {
        // Representative real-device serials from the matrix the
        // bridge has been tested against.
        let serials = [
            "R5CT1ABCD12",
            "7CKDU16C09042428",
            "0123456789ABCDEF",
            "192.168.1.5:5555",
        ]
        for serial in serials {
            #expect(PlatformRouter.resolve(udid: serial) == .android,
                    "expected \(serial) to route to android")
        }
    }

    @Test("Empty UDID returns nil and forwarder defaults to iOSSim")
    func emptyUdidNilThenIOSDefault() {
        #expect(PlatformRouter.resolve(udid: "") == nil)
        // The `Tap.execute()` switch treats `.none` and `.iOSSim` as
        // the same branch — when we can't classify, the iOS resolver
        // owns the failure surface. Mirror that here so the test is
        // tied to the same decision.
        let routed: Platform = PlatformRouter.resolve(udid: "") ?? .iOSSim
        #expect(routed == .iOSSim)
    }

    // MARK: - Validation parity

    @Test("Shared targeting validator rejects conflicting selectors")
    func conflictingSelectorsRejected() throws {
        // The rules live on the shared group — parse a targeting group
        // with conflicting selectors and run the validator directly.
        // (Direct `TapTargetingOptions()` construction would trap on
        // first read — the #41/#42 failure class — so tests go through
        // `parse` like every real surface does.)
        let targeting = try TapTargetingOptions.parse(["--id", "Some", "--label", "Other"])
        do {
            try targeting.validate(alias: nil)
            Issue.record("expected a ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("Use only one of"))
        } catch {
            Issue.record("expected ValidationError, got \(type(of: error))")
        }
    }

    @Test("Alias-with-coordinates is rejected by shared validator")
    func aliasWithCoordsConflict() throws {
        let targeting = try TapTargetingOptions.parse(["-x", "100", "-y", "200"])
        do {
            try targeting.validate(alias: "@2")
            Issue.record("expected a ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("Alias '@2' cannot be combined"))
        } catch {
            Issue.record("expected ValidationError, got \(type(of: error))")
        }
    }

    @Test("Wait timeout requires positive poll interval")
    func waitTimeoutRequiresPollInterval() {
        // `TapTimingOptions.validate()` is the ParsableArguments
        // witness, and a *standalone* `parse` of the group wraps it in
        // a synthetic root command — so the rule fires during parse
        // (unlike when the group is nested in a command, where the
        // command's explicit `timing.validate()` call is load-bearing).
        do {
            _ = try TapTimingOptions.parse(["--wait-timeout", "5", "--poll-interval", "0"])
            Issue.record("expected a validation failure")
        } catch {
            #expect(TapTimingOptions.message(for: error).contains("--poll-interval"))
        }
    }

    @Test("Empty selector value is rejected")
    func emptySelectorValueRejected() throws {
        let targeting = try TapTargetingOptions.parse(["--id", "   "])
        do {
            try targeting.validate(alias: nil)
            Issue.record("expected a ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("must not be empty"))
        } catch {
            Issue.record("expected ValidationError, got \(type(of: error))")
        }
    }

    // MARK: - Flag-surface parity

    // MARK: - Symmetric forwarder contract

    @Test("AndroidTapCommand.performTap is callable with the forwarder's argument shape")
    func androidTapPerformContract() {
        // We can't dial a real device from a unit test, but we can
        // assert the static helper exists with the exact signature
        // the top-level `Tap.executeAndroid` calls into. If a future
        // refactor renames a parameter or changes the return type,
        // this fails at compile time — the goal of the test.
        let _: (
            String,
            String?,
            Int?, Int?,
            AndroidSelector,
            Double?,
            MultiTouchOptions?,
            AndroidDeviceController
        ) throws -> (x: Int, y: Int, description: String) = AndroidTapCommand.performTap

        // Sanity: the AndroidSelector used by the forwarder accepts
        // all the same fields the top-level cross-platform flags
        // produce. If AndroidSelector's init drops a parameter this
        // forces the forwarder author to follow.
        _ = AndroidSelector(
            id: nil,
            label: nil,
            labelContains: nil,
            labelRegex: nil,
            value: nil,
            valueContains: nil,
            valueRegex: nil,
            elementType: nil,
            frame: nil
        )
    }

    @Test("performTap without multiTouch throws instead of trapping")
    func androidTapDefaultMultiTouchDoesNotTrap() {
        // Regression for the `sim-use android tap` crash: the old
        // `multiTouch: MultiTouchOptions = MultiTouchOptions()` default
        // was a directly-initialized ParsableArguments value, and the
        // first `.fingers` read inside performTap hit ArgumentParser's
        // "can't read a value from a parsable argument definition"
        // fatal — before the bridge was ever dialled. With the optional
        // default the unreachable device must surface as a thrown
        // BridgeError (adb missing or device not found, depending on
        // the host), never a process trap.
        #expect(throws: (any Error).self) {
            _ = try AndroidTapCommand.performTap(
                udid: "nonexistent-serial-0000",
                alias: nil,
                x: 100, y: 200,
                selector: AndroidSelector(
                    id: nil,
                    label: nil,
                    labelContains: nil,
                    labelRegex: nil,
                    value: nil,
                    valueContains: nil,
                    valueRegex: nil,
                    elementType: nil,
                    frame: nil
                ),
                duration: nil
            )
        }
    }

    @Test("ArgumentParser parses both top-level Tap and IOSSimTapCommand with same flags")
    func flagSurfaceParses() throws {
        // The two structs must accept the same argv tail. Pick a
        // realistic invocation that touches a selector flag, frame,
        // delays, and UDID — if either side drops a flag, parse fails
        // (ArgumentParser runs `validate()` from `parse(_:)`, so the
        // chosen combination has to be valid).
        let argv = [
            "--label-contains", "foo",
            "--element-type", "Button",
            "--frame", "minX=10,maxX=200",
            "--pre-delay", "0.1",
            "--duration", "0.05",
            "--wait-timeout", "1.0",
            "--poll-interval", "0.5",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
            "--json"
        ]
        let topLevel = try Tap.parse(argv)
        let subCmd = try IOSSimTapCommand.parse(argv)

        // Cross-check a sample of fields landed in both structs.
        #expect(topLevel.targeting.labelContains == "foo")
        #expect(subCmd.targeting.labelContains == "foo")
        #expect(topLevel.targeting.elementType == "Button")
        #expect(subCmd.targeting.elementType == "Button")
        #expect(topLevel.targeting.frameSpecs == ["minX=10,maxX=200"])
        #expect(subCmd.targeting.frameSpecs == ["minX=10,maxX=200"])
        #expect(topLevel.duration == 0.05)
        #expect(subCmd.duration == 0.05)
        #expect(topLevel.jsonOutput == true)
        #expect(subCmd.jsonOutput == true)
    }

    @Test("--point parses on every tap surface")
    func pointFlagParsesEverywhere() throws {
        // Issue #25: the coordinate-pair form must exist on the
        // top-level, iOS, and Android surfaces plus long-press. Batch
        // is covered transitively — `BatchStepParser` parses tap steps
        // through `IOSSimTapCommand` itself.
        let expected = CoordinatePair(x: 100, y: 200)
        let iosArgv = ["--point", "100,200", "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0"]
        #expect(try Tap.parse(iosArgv).targeting.point == expected)
        #expect(try IOSSimTapCommand.parse(iosArgv).targeting.point == expected)
        #expect(try LongPress.parse(iosArgv).targeting.point == expected)

        let androidArgv = ["--point", "100,200", "--udid", "emulator-5554"]
        #expect(try AndroidTapCommand.parse(androidArgv).point == expected)
    }

    @Test("AndroidTapCommand parses --duration and rejects out-of-range")
    func androidDurationFlag() throws {
        // Plain `--duration` is accepted on `sim-use android tap` and
        // routes to `BridgeClient.swipe(start=end, durationMs)` at
        // execute time — the long-press recipe. We can't dial a real
        // device here, so the test pins the parse + validation surface.
        let parsed = try AndroidTapCommand.parse([
            "--udid", "emulator-5554",
            "-x", "100", "-y", "200",
            "--duration", "0.8"
        ])
        #expect(parsed.duration == 0.8)

        let omitted = try AndroidTapCommand.parse([
            "--udid", "emulator-5554",
            "-x", "100", "-y", "200"
        ])
        #expect(omitted.duration == nil)

        // ArgumentParser runs `validate()` during `parse(_:)`, so an
        // out-of-range duration surfaces as a parser error rather than
        // a separately-invoked validation failure.
        #expect(throws: (any Error).self) {
            _ = try AndroidTapCommand.parse([
                "--udid", "emulator-5554",
                "-x", "100", "-y", "200",
                "--duration", "11"
            ])
        }
    }

    @Test("LongPress mirrors Tap's flag surface and defaults --duration to 0.8")
    func longPressFlagSurface() throws {
        // `long-press` is sugar over `tap --duration` — it must accept
        // the exact same argv tail as `Tap`, and `--duration` must
        // default to 0.8 when omitted (the long-press threshold). If
        // this drifts (someone renames a flag on one side or changes
        // the default), the test fails at parse time.
        let argv = [
            "--label-contains", "foo",
            "--element-type", "Button",
            "--frame", "minX=10,maxX=200",
            "--pre-delay", "0.1",
            "--wait-timeout", "1.0",
            "--poll-interval", "0.5",
            "--udid", "emulator-5554",
            "--json"
        ]
        let topTap = try Tap.parse(argv)
        let topLong = try LongPress.parse(argv)

        #expect(topLong.targeting.labelContains == topTap.targeting.labelContains)
        #expect(topLong.targeting.elementType == topTap.targeting.elementType)
        #expect(topLong.targeting.frameSpecs == topTap.targeting.frameSpecs)
        #expect(topLong.timing.preDelay == topTap.timing.preDelay)
        #expect(topLong.timing.waitTimeout == topTap.timing.waitTimeout)
        #expect(topLong.timing.pollInterval == topTap.timing.pollInterval)
        #expect(topLong.jsonOutput == topTap.jsonOutput)

        // Default --duration: Tap leaves it nil (no hold), long-press
        // promotes to 0.8 to cross the OS long-press threshold.
        #expect(topTap.duration == nil)
        #expect(topLong.duration == 0.8)

        // Explicit override still wins.
        let explicit = try LongPress.parse([
            "--udid", "emulator-5554",
            "-x", "100", "-y", "200",
            "--duration", "1.2"
        ])
        #expect(explicit.duration == 1.2)

        // Range validation reuses the shared tap rules (0–10s).
        #expect(throws: (any Error).self) {
            _ = try LongPress.parse([
                "--udid", "emulator-5554",
                "-x", "100", "-y", "200",
                "--duration", "11"
            ])
        }
    }
}