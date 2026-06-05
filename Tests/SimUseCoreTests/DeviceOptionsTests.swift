// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import Testing
@testable import SimUseCore

/// Stand-alone command used to exercise `DeviceOptions` as an
/// `@OptionGroup`. Keeping the test fixture local to the suite keeps
/// the production verbs out of SimUseCoreTests' import surface
/// (iOSSimBackend is the home of every concrete IOSSim<Verb>Command).
private struct ProbeCommand: ParsableArguments {
    @OptionGroup var device: DeviceOptions
    init() {}
}

private struct AndroidProbeCommand: ParsableArguments {
    @OptionGroup var device: AndroidDeviceOptions
    init() {}
}

@Suite("DeviceOptions — parsing")
struct DeviceOptionsParseTests {
    @Test("explicit --device lands in device property, resolved stays empty pre-resolve")
    func explicitDevicePopulates() throws {
        let probe = try ProbeCommand.parse(["--device", "FAKE-ID"])
        #expect(probe.device.device == "FAKE-ID")
        #expect(probe.device.udid == nil)
        #expect(probe.device.resolved == "")
    }

    @Test("legacy --udid still parses, lands in udid property")
    func legacyUDIDPopulates() throws {
        let probe = try ProbeCommand.parse(["--udid", "LEGACY-ID"])
        #expect(probe.device.device == nil)
        #expect(probe.device.udid == "LEGACY-ID")
    }

    @Test("absent flags leave both nil")
    func absentFlagsAreNil() throws {
        let probe = try ProbeCommand.parse([])
        #expect(probe.device.device == nil)
        #expect(probe.device.udid == nil)
        #expect(probe.device.resolved == "")
    }

    @Test("--device=value equals-form parses identically to space-separated")
    func equalsFormParses() throws {
        let probe = try ProbeCommand.parse(["--device=FAKE-ID"])
        #expect(probe.device.device == "FAKE-ID")
    }
}

@Suite("DeviceOptions — resolve()")
struct DeviceOptionsResolveTests {
    @Test("--device with iOS-shape value flows through DeviceResolver, trimmed verbatim")
    func deviceIOSShapePassesThrough() throws {
        var probe = try ProbeCommand.parse(["--device", "  FAKE-UDID  "])
        try probe.device.resolve()
        #expect(probe.device.resolved == "FAKE-UDID")
    }

    @Test("--udid (deprecated alias) resolves identically to --device")
    func udidAliasResolvesIdentically() throws {
        var withDevice = try ProbeCommand.parse(["--device", "FAKE-UDID"])
        var withUDID = try ProbeCommand.parse(["--udid", "FAKE-UDID"])
        try withDevice.device.resolve()
        try withUDID.device.resolve()
        #expect(withDevice.device.resolved == withUDID.device.resolved)
        #expect(withUDID.device.resolved == "FAKE-UDID")
    }

    @Test("passing both --device and --udid is a fast-fail ValidationError")
    func bothFlagsConflict() throws {
        var probe = try ProbeCommand.parse(["--device", "A", "--udid", "B"])
        do {
            try probe.device.resolve()
            Issue.record("expected ValidationError for --device + --udid")
        } catch is CLIError {
            // Expected — CLIError, not ValidationError; see
            // DeviceOptions.selectExplicit for the rationale.
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("Android-shape value bypasses DeviceResolver entirely")
    func androidShapeBypasses() throws {
        // `emulator-5554` matches PlatformRouter.looksLikeAndroid; the
        // bypass branch should accept it without consulting the
        // iOS-only booted-list provider. We don't need to inject a
        // provider — if the bypass were broken, resolve() would try
        // simctl and (most likely) fail in CI sandboxes.
        var probe = try ProbeCommand.parse(["--device", "emulator-5554"])
        try probe.device.resolve()
        #expect(probe.device.resolved == "emulator-5554")
    }

    @Test("Android-shape value via --udid alias also bypasses the resolver")
    func androidShapeViaUDID() throws {
        var probe = try ProbeCommand.parse(["--udid", "emulator-5554"])
        try probe.device.resolve()
        #expect(probe.device.resolved == "emulator-5554")
    }

    @Test("whitespace-only --device does not short-circuit the bypass")
    func emptyExplicitFallsThroughToResolver() throws {
        // A `--device "   "` should NOT trigger the Android bypass
        // (looksLikeAndroid returns false on empty input); resolve()
        // falls through to DeviceResolver.resolve which then ignores
        // the empty string and continues with auto-resolution. Without
        // a booted simulator on the box this surfaces as a
        // ResolutionError — we only assert that the error originates
        // from the resolver, not from the bypass branch.
        var probe = try ProbeCommand.parse(["--device", "   "])
        do {
            try probe.device.resolve()
            #expect(!probe.device.resolved.isEmpty)
        } catch is DeviceResolver.ResolutionError {
            // Expected outcome on a CI box without booted sims.
        }
    }

    @Test("selectExplicit static helper returns nil when neither flag set")
    func selectExplicitEmpty() throws {
        #expect(try DeviceOptions.selectExplicit(device: nil, udid: nil) == nil)
        #expect(try DeviceOptions.selectExplicit(device: "  ", udid: "  ") == nil)
    }

    @Test("selectExplicit picks --device when only --device is set")
    func selectExplicitDeviceOnly() throws {
        let picked = try DeviceOptions.selectExplicit(device: "A", udid: nil)
        #expect(picked == "A")
    }

    @Test("selectExplicit picks --udid when only --udid is set")
    func selectExplicitUDIDOnly() throws {
        let picked = try DeviceOptions.selectExplicit(device: nil, udid: "B")
        #expect(picked == "B")
    }

    @Test("selectExplicit rejects both set")
    func selectExplicitBothSet() throws {
        do {
            _ = try DeviceOptions.selectExplicit(device: "A", udid: "B")
            Issue.record("expected ValidationError")
        } catch is CLIError {
            // Expected — CLIError, not ValidationError; see
            // DeviceOptions.selectExplicit for the rationale.
        }
    }
}

@Suite("AndroidDeviceOptions — required-explicit semantics")
struct AndroidDeviceOptionsTests {
    @Test("--device alone resolves to the passed serial")
    func deviceAlone() throws {
        var probe = try AndroidProbeCommand.parse(["--device", "emulator-5554"])
        try probe.device.resolve()
        #expect(probe.device.resolved == "emulator-5554")
    }

    @Test("--udid (legacy alias) alone also resolves")
    func legacyAlone() throws {
        var probe = try AndroidProbeCommand.parse(["--udid", "emulator-5554"])
        try probe.device.resolve()
        #expect(probe.device.resolved == "emulator-5554")
    }

    @Test("missing both flags throws a CLIError pointing at --device")
    func missingFlagsErrorsClearly() throws {
        var probe = try AndroidProbeCommand.parse([])
        do {
            try probe.device.resolve()
            Issue.record("expected CLIError when no --device / --udid is set")
        } catch let error as CLIError {
            // The error description should name --device so a fresh
            // Android engineer sees the new flag, not the legacy one.
            let message = error.errorDescription ?? ""
            #expect(message.contains("--device"))
        }
    }

    @Test("passing both --device and --udid is a fast-fail")
    func bothFlagsErrors() throws {
        var probe = try AndroidProbeCommand.parse(["--device", "A", "--udid", "B"])
        do {
            try probe.device.resolve()
            Issue.record("expected ValidationError")
        } catch is CLIError {
            // Expected — CLIError, not ValidationError; see
            // DeviceOptions.selectExplicit for the rationale.
        }
    }
}