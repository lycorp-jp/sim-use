// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import AndroidBackend
import ArgumentParser
import Foundation
import SimUseCore
import Testing

// Pins the hardening added on top of the coordinate-pair ergonomics:
// one shared `SwipeCoordinateOptions` group with one set of range
// rules on every surface, a seconds-only duration ceiling, and
// success lines rendered from the execution result instead of a
// re-resolution of the raw flags.
@Suite("Swipe validation hardening")
@MainActor
struct SwipeValidationHardeningTests {

    // MARK: - CoordinatePair parse guards

    @Test("CoordinatePair rejects non-finite and malformed input")
    func coordinatePairRejectsNonFinite() {
        #expect(CoordinatePair(argument: "inf,0") == nil)
        #expect(CoordinatePair(argument: "-inf,0") == nil)
        #expect(CoordinatePair(argument: "nan,nan") == nil)
        #expect(CoordinatePair(argument: "1e400,0") == nil)
        #expect(CoordinatePair(argument: "100") == nil)
        #expect(CoordinatePair(argument: "1,2,3") == nil)
        #expect(CoordinatePair(argument: "100, 200") == CoordinatePair(x: 100, y: 200))
    }

    // MARK: - Resolver range rules (reachable from every surface)

    @Test("Resolver rejects non-finite legacy flag values")
    func resolverRejectsNonFinite() {
        for bad in [Double.infinity, Double.nan] {
            do {
                _ = try SwipeCoordinateResolver.resolve(
                    startX: bad, startY: 0, endX: 10, endY: 10,
                    from: nil, to: nil, positional: []
                )
                Issue.record("expected a ValidationError for \(bad)")
            } catch let error as ValidationError {
                #expect(error.message.contains("finite"))
            } catch {
                Issue.record("expected ValidationError, got \(type(of: error))")
            }
        }
    }

    @Test("Resolver rejects coordinates beyond the maximum, accepts the boundary")
    func resolverRejectsOversized() throws {
        do {
            _ = try SwipeCoordinateResolver.resolve(
                startX: 1e19, startY: 0, endX: 10, endY: 10,
                from: nil, to: nil, positional: []
            )
            Issue.record("expected a ValidationError for 1e19")
        } catch let error as ValidationError {
            #expect(error.message.contains("at most"))
        }

        let max = SwipeCoordinateResolver.maximumCoordinate
        let coords = try SwipeCoordinateResolver.resolve(
            startX: max, startY: 0, endX: 0, endY: 0,
            from: nil, to: nil, positional: []
        )
        #expect(coords.startX == max)
    }

    @Test("Android surface rejects same-point and negative coordinates at parse time")
    func androidSurfaceEnforcesRangeRules() {
        #expect(throws: (any Error).self) {
            _ = try AndroidSwipeCommand.parse(["--from", "5,5", "--to", "5,5", "--device", "emulator-5554"])
        }
        #expect(throws: (any Error).self) {
            _ = try AndroidSwipeCommand.parse(["--start-x", "-5", "--start-y", "-5", "--end-x", "20", "--end-y", "20", "--device", "emulator-5554"])
        }
    }

    // MARK: - Duration ceiling (seconds, not milliseconds)

    @Test("Android swipe rejects millisecond-style durations with a seconds hint")
    func androidDurationCapped() throws {
        var cmd = try AndroidSwipeCommand.parse(["--from", "0,800", "--to", "0,200", "--device", "emulator-5554"])
        cmd.duration = 300
        do {
            try cmd.validate()
            Issue.record("expected a ValidationError for duration 300")
        } catch let error as ValidationError {
            #expect(error.message.contains("milliseconds"))
        }

        cmd.duration = 10
        try cmd.validate()
    }

    @Test("iOS/top-level timing validation caps duration at 10 seconds")
    func timingDurationCapped() throws {
        do {
            try IOSSimSwipeCommand.validateTimingOptions(
                duration: 300, delta: nil, preDelay: nil, postDelay: nil
            )
            Issue.record("expected a ValidationError for duration 300")
        } catch let error as ValidationError {
            #expect(error.message.contains("milliseconds"))
        }

        try IOSSimSwipeCommand.validateTimingOptions(
            duration: 10, delta: nil, preDelay: nil, postDelay: nil
        )
    }

    // MARK: - Surface parity via the shared OptionGroup

    @Test("Android swipe parses positional and legacy forms like the other surfaces")
    func androidParsesAllForms() throws {
        let expected = SwipeCoordinates(startX: 100, startY: 200, endX: 300, endY: 400)

        let positional = try AndroidSwipeCommand.parse(["100,200", "300,400", "--device", "emulator-5554"])
        #expect(try positional.resolvedCoordinates() == expected)

        let legacy = try AndroidSwipeCommand.parse([
            "--start-x", "100", "--start-y", "200",
            "--end-x", "300", "--end-y", "400",
            "--device", "emulator-5554"
        ])
        #expect(try legacy.resolvedCoordinates() == expected)
    }

    // MARK: - format() renders from the execution result

    @Test("Success lines derive from ExecutionResult with unified rounding")
    func formatRendersFromResult() throws {
        let coords = SwipeCoordinates(startX: 100.4, startY: 200, endX: 300.5, endY: 400)
        #expect(coords.displaySummary == "(100,200) → (301,400)")

        // Parse each surface with *different* coordinates than the
        // result carries: the success line must show the result's,
        // proving format() no longer re-resolves the raw flags.
        let udid = ["--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0"]

        let topLevel = try Swipe.parse(["1,2", "3,4"] + udid).format(.init(coordinates: coords))
        #expect(topLevel.stdout.contains("✓ Swipe (100,200) → (301,400) completed successfully"))

        let ios = try IOSSimSwipeCommand.parse(["1,2", "3,4"] + udid).format(.init(coordinates: coords))
        #expect(ios.stdout.contains("✓ Swipe (100,200) → (301,400) completed successfully"))

        let android = try AndroidSwipeCommand.parse(["1,2", "3,4", "--device", "emulator-5554"])
            .format(.init(coordinates: coords))
        #expect(android.stdout.contains("✓ Swipe (100,200) → (301,400) completed successfully"))
        #expect(android.stderr.contains("duration=300ms"))
    }

    @Test("ExecutionResult round-trips through the daemon JSON envelope")
    func executionResultRoundTrips() throws {
        let coords = SwipeCoordinates(startX: 100, startY: 200, endX: 300, endY: 400)
        let encoded = try JSONEncoder().encode(IOSSimSwipeCommand.ExecutionResult(coordinates: coords))
        let decoded = try JSONDecoder().decode(IOSSimSwipeCommand.ExecutionResult.self, from: encoded)
        #expect(decoded.coordinates == coords)

        let androidEncoded = try JSONEncoder().encode(AndroidSwipeCommand.ExecutionResult(coordinates: coords))
        let androidDecoded = try JSONDecoder().decode(AndroidSwipeCommand.ExecutionResult.self, from: androidEncoded)
        #expect(androidDecoded.coordinates == coords)
    }
}
