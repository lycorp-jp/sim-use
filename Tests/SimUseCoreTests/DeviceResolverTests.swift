// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import Foundation
import Testing

private typealias Resolver = DeviceResolver
private typealias BootedSimulator = DeviceResolver.BootedSimulator
private typealias ResolutionError = DeviceResolver.ResolutionError

private let neverCalledProvider: Resolver.BootedListProvider = {
    Issue.record("simctl booted-list provider should not have been invoked")
    return []
}

/// Drop a fake daemon footprint (pidfile owned by the test process)
/// inside `baseDir`. The pid is the test process itself so
/// `kill(pid, 0)` succeeds; that's how `DaemonPaths.filesystemLiveness`
/// decides the daemon is "probably alive". The matching `.sock` file is
/// also created because filesystemLiveness short-circuits on its absence.
private func makeFakeDaemon(udid: String, in baseDir: URL) throws {
    let paths = DaemonPaths(udid: udid, baseDirectory: baseDir)
    try paths.ensureBaseDirectory()
    try Data().write(to: paths.socketURL)
    try paths.writePidfile(getpid())
}

private func makeTempDir() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sim-use-device-resolver-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Resolution order

@Suite("DeviceResolver — explicit and env paths")
struct DeviceResolverFastPathTests {
    @Test("explicit --device wins over everything")
    func explicitWins() throws {
        let baseDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        try makeFakeDaemon(udid: "DAEMON-UDID", in: baseDir)

        let resolved = try Resolver.resolve(
            explicit: "EXPLICIT-UDID",
            environment: ["SIM_USE_DEVICE": "ENV-DEVICE", "SIM_USE_UDID": "ENV-UDID"],
            baseDirectory: baseDir,
            bootedListProvider: neverCalledProvider
        )
        #expect(resolved == "EXPLICIT-UDID")
    }

    @Test("trims surrounding whitespace on explicit value")
    func explicitTrimmed() throws {
        let resolved = try Resolver.resolve(
            explicit: "  EXPLICIT-UDID  ",
            environment: [:],
            baseDirectory: makeTempDir(),
            bootedListProvider: neverCalledProvider
        )
        #expect(resolved == "EXPLICIT-UDID")
    }

    @Test("SIM_USE_DEVICE wins when no explicit is given")
    func envDeviceWins() throws {
        let baseDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        try makeFakeDaemon(udid: "DAEMON-UDID", in: baseDir)

        let resolved = try Resolver.resolve(
            explicit: nil,
            environment: ["SIM_USE_DEVICE": "ENV-DEVICE"],
            baseDirectory: baseDir,
            bootedListProvider: neverCalledProvider
        )
        #expect(resolved == "ENV-DEVICE")
    }

    @Test("SIM_USE_UDID (legacy alias) still resolves when SIM_USE_DEVICE is absent")
    func envUDIDFallback() throws {
        let baseDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        try makeFakeDaemon(udid: "DAEMON-UDID", in: baseDir)

        let resolved = try Resolver.resolve(
            explicit: nil,
            environment: ["SIM_USE_UDID": "ENV-UDID"],
            baseDirectory: baseDir,
            bootedListProvider: neverCalledProvider
        )
        #expect(resolved == "ENV-UDID")
    }

    @Test("both env vars set is a fast-fail")
    func conflictingEnvVars() throws {
        do {
            _ = try Resolver.resolve(
                explicit: nil,
                environment: ["SIM_USE_DEVICE": "X", "SIM_USE_UDID": "Y"],
                baseDirectory: makeTempDir(),
                bootedListProvider: neverCalledProvider
            )
            Issue.record("expected conflictingEnvVars")
        } catch let error as ResolutionError {
            guard case .conflictingEnvVars = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            let message = error.errorDescription ?? ""
            #expect(message.contains("SIM_USE_DEVICE"))
            #expect(message.contains("SIM_USE_UDID"))
        }
    }

    @Test("blank explicit falls through, blank env also falls through")
    func blankValuesFallThrough() throws {
        let baseDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        try makeFakeDaemon(udid: "DAEMON-UDID", in: baseDir)

        let resolved = try Resolver.resolve(
            explicit: "   ",
            environment: ["SIM_USE_DEVICE": "   ", "SIM_USE_UDID": "   "],
            baseDirectory: baseDir,
            bootedListProvider: neverCalledProvider
        )
        #expect(resolved == "DAEMON-UDID")
    }
}

@Suite("DeviceResolver — daemon-presence path")
struct DeviceResolverDaemonPathTests {
    @Test("exactly one alive daemon resolves to its UDID without consulting simctl")
    func singleDaemonResolves() throws {
        let baseDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        try makeFakeDaemon(udid: "ONLY-DAEMON", in: baseDir)

        let resolved = try Resolver.resolve(
            explicit: nil,
            environment: [:],
            baseDirectory: baseDir,
            bootedListProvider: neverCalledProvider
        )
        #expect(resolved == "ONLY-DAEMON")
    }

    @Test("multiple alive daemons fall through to simctl")
    func multipleDaemonsFallThrough() throws {
        let baseDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        try makeFakeDaemon(udid: "DAEMON-A", in: baseDir)
        try makeFakeDaemon(udid: "DAEMON-B", in: baseDir)

        var providerCalled = false
        let resolved = try Resolver.resolve(
            explicit: nil,
            environment: [:],
            baseDirectory: baseDir,
            bootedListProvider: {
                providerCalled = true
                return [BootedSimulator(udid: "BOOTED-X", name: "iPhone X")]
            }
        )
        #expect(providerCalled)
        #expect(resolved == "BOOTED-X")
    }

    @Test("zero alive daemons fall through to simctl")
    func zeroDaemonsFallThrough() throws {
        let baseDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let resolved = try Resolver.resolve(
            explicit: nil,
            environment: [:],
            baseDirectory: baseDir,
            bootedListProvider: {
                [BootedSimulator(udid: "BOOTED-X", name: "iPhone X")]
            }
        )
        #expect(resolved == "BOOTED-X")
    }
}

@Suite("DeviceResolver — simctl fallback path")
struct DeviceResolverSimctlPathTests {
    private func resolverWith(_ booted: [BootedSimulator]) throws -> String {
        try Resolver.resolve(
            explicit: nil,
            environment: [:],
            baseDirectory: makeTempDir(),
            bootedListProvider: { booted }
        )
    }

    @Test("exactly one booted simulator resolves")
    func singleBootedResolves() throws {
        let resolved = try resolverWith([BootedSimulator(udid: "ONLY-BOOTED", name: "iPhone")])
        #expect(resolved == "ONLY-BOOTED")
    }

    @Test("zero booted throws noSimulatorBooted with no hint, message names --device")
    func zeroBootedThrows() throws {
        do {
            _ = try resolverWith([])
            Issue.record("expected noSimulatorBooted")
        } catch let error as ResolutionError {
            guard case .noSimulatorBooted = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(error.errorDescription?.contains("No simulator is booted") == true)
            #expect(error.errorDescription?.contains("--device") == true)
            #expect(error.hint == nil)
        }
    }

    @Test("multiple booted throws and hint lists all UDIDs and names")
    func multipleBootedHint() throws {
        let booted = [
            BootedSimulator(udid: "UDID-A", name: "iPhone 17 Pro"),
            BootedSimulator(udid: "UDID-B", name: "iPad Air"),
        ]
        do {
            _ = try resolverWith(booted)
            Issue.record("expected multipleSimulatorsBooted")
        } catch let error as ResolutionError {
            guard case .multipleSimulatorsBooted(let udids, _) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(udids == ["UDID-A", "UDID-B"])
            let hint = error.hint ?? ""
            #expect(hint.contains("UDID-A"))
            #expect(hint.contains("UDID-B"))
            #expect(hint.contains("iPhone 17 Pro"))
            #expect(hint.contains("iPad Air"))
        }
    }

    @Test("multiple booted errorDescription inlines the simulator list and names --device / SIM_USE_DEVICE")
    func multipleBootedDescription() throws {
        let booted = [
            BootedSimulator(udid: "UDID-A", name: "iPhone 17 Pro"),
            BootedSimulator(udid: "UDID-B", name: "iPad Air"),
        ]
        do {
            _ = try resolverWith(booted)
            Issue.record("expected multipleSimulatorsBooted")
        } catch let error as ResolutionError {
            // Plain-text consumers (validate-time errors, non-JSON CLI
            // output) only see errorDescription; if the list is missing
            // there the user has no way to disambiguate without a
            // separate `list-simulators` round-trip.
            let message = error.errorDescription ?? ""
            #expect(message.contains("(2)"))
            #expect(message.contains("UDID-A"))
            #expect(message.contains("UDID-B"))
            #expect(message.contains("iPhone 17 Pro"))
            #expect(message.contains("iPad Air"))
            #expect(message.contains("--device"))
            #expect(message.contains("SIM_USE_DEVICE"))
        }
    }

    @Test("provider error surfaces as simctlFailed")
    func providerErrorSurfaces() throws {
        struct Boom: Swift.Error, LocalizedError {
            var errorDescription: String? { "exec failed" }
        }
        do {
            _ = try Resolver.resolve(
                explicit: nil,
                environment: [:],
                baseDirectory: makeTempDir(),
                bootedListProvider: { throw Boom() }
            )
            Issue.record("expected simctlFailed")
        } catch let error as ResolutionError {
            guard case .simctlFailed(let message) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(message.contains("exec failed"))
        }
    }
}

// MARK: - injectingDeviceIfNeeded — the bridge between client and daemon

@Suite("DeviceResolver.injectingDeviceIfNeeded")
struct DeviceArgInjectionTests {
    @Test("appends --device + value when missing")
    func appendsWhenMissing() {
        let out = Resolver.injectingDeviceIfNeeded(["@5"], device: "RESOLVED")
        #expect(out == ["@5", "--device", "RESOLVED"])
    }

    @Test("preserves existing --device <value> form")
    func preservesDeviceSpaceForm() {
        let out = Resolver.injectingDeviceIfNeeded(["--device", "EXPLICIT", "@5"], device: "OTHER")
        #expect(out == ["--device", "EXPLICIT", "@5"])
    }

    @Test("preserves existing --device=<value> form")
    func preservesDeviceEqualsForm() {
        let out = Resolver.injectingDeviceIfNeeded(["--device=EXPLICIT", "@5"], device: "OTHER")
        #expect(out == ["--device=EXPLICIT", "@5"])
    }

    @Test("preserves existing --udid <value> form (legacy alias)")
    func preservesUDIDSpaceForm() {
        let out = Resolver.injectingDeviceIfNeeded(["--udid", "EXPLICIT", "@5"], device: "OTHER")
        #expect(out == ["--udid", "EXPLICIT", "@5"])
    }

    @Test("preserves existing --udid=<value> form (legacy alias)")
    func preservesUDIDEqualsForm() {
        let out = Resolver.injectingDeviceIfNeeded(["--udid=EXPLICIT", "@5"], device: "OTHER")
        #expect(out == ["--udid=EXPLICIT", "@5"])
    }

    @Test("empty argv gets a fresh --device pair")
    func emptyArgs() {
        let out = Resolver.injectingDeviceIfNeeded([], device: "RESOLVED")
        #expect(out == ["--device", "RESOLVED"])
    }

    @Test("idempotent: a second injection with the same value is a no-op")
    func idempotent() {
        let once = Resolver.injectingDeviceIfNeeded(["@5"], device: "RESOLVED")
        let twice = Resolver.injectingDeviceIfNeeded(once, device: "RESOLVED")
        #expect(once == twice)
    }
}

// MARK: - simctl JSON parsing

@Suite("DeviceResolver.parseSimctlBootedJSON")
struct DeviceResolverParseTests {
    @Test("parses the single-runtime shape")
    func singleRuntime() throws {
        let json = #"""
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
              { "udid": "ABCD", "name": "iPhone 17 Pro", "state": "Booted" }
            ]
          }
        }
        """#
        let parsed = try Resolver.parseSimctlBootedJSON(Data(json.utf8))
        #expect(parsed == [BootedSimulator(udid: "ABCD", name: "iPhone 17 Pro")])
    }

    @Test("flattens across multiple runtimes and sorts by UDID")
    func multipleRuntimes() throws {
        let json = #"""
        {
          "devices": {
            "iOS-26": [{ "udid": "ZZZ", "name": "iPad" }],
            "iOS-18": [{ "udid": "AAA", "name": "iPhone" }]
          }
        }
        """#
        let parsed = try Resolver.parseSimctlBootedJSON(Data(json.utf8))
        #expect(parsed.map(\.udid) == ["AAA", "ZZZ"])
    }

    @Test("empty device list yields empty result, not an error")
    func emptyList() throws {
        let json = #"{"devices": {}}"#
        let parsed = try Resolver.parseSimctlBootedJSON(Data(json.utf8))
        #expect(parsed.isEmpty)
    }

    @Test("malformed JSON throws simctlFailed")
    func malformed() throws {
        do {
            _ = try Resolver.parseSimctlBootedJSON(Data("not json".utf8))
            Issue.record("expected simctlFailed")
        } catch let error as ResolutionError {
            guard case .simctlFailed = error else {
                Issue.record("wrong case: \(error)")
                return
            }
        }
    }
}