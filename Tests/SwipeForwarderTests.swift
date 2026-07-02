// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import AndroidBackend
import ArgumentParser
import Foundation
import SimUseCore
import Testing

// Pins the contract between top-level `Swipe` and the
// `IOSSimSwipeCommand` it forwards to. Mirrors `TapForwarderTests`.
@Suite("Swipe forwarder")
@MainActor
struct SwipeForwarderTests {

    // MARK: - Validation parity

    @Test("Top-level Swipe validation delegates to IOSSimSwipeCommand (negative coords)")
    func negativeCoordsRejected() {
        do {
            _ = try IOSSimSwipeCommand.validateOptions(
                startX: -1, startY: 0, endX: 10, endY: 10,
                duration: nil, delta: nil,
                preDelay: nil, postDelay: nil
            )
            Issue.record("expected a ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("non-negative"))
        } catch {
            Issue.record("expected ValidationError, got \(type(of: error))")
        }
    }

    @Test("Same start and end is rejected")
    func samePointRejected() {
        do {
            _ = try IOSSimSwipeCommand.validateOptions(
                startX: 100, startY: 100, endX: 100, endY: 100,
                duration: nil, delta: nil,
                preDelay: nil, postDelay: nil
            )
            Issue.record("expected a ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("Start and end points must be different"))
        } catch {
            Issue.record("expected ValidationError, got \(type(of: error))")
        }
    }

    @Test("Non-positive duration is rejected")
    func nonPositiveDurationRejected() {
        do {
            _ = try IOSSimSwipeCommand.validateOptions(
                startX: 100, startY: 100, endX: 200, endY: 200,
                duration: 0, delta: nil,
                preDelay: nil, postDelay: nil
            )
            Issue.record("expected a ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("Duration must be greater than 0"))
        } catch {
            Issue.record("expected ValidationError, got \(type(of: error))")
        }
    }

    @Test("Out-of-range pre-delay is rejected")
    func preDelayOutOfRangeRejected() {
        do {
            _ = try IOSSimSwipeCommand.validateOptions(
                startX: 100, startY: 100, endX: 200, endY: 200,
                duration: nil, delta: nil,
                preDelay: 11, postDelay: nil
            )
            Issue.record("expected a ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("Pre-delay"))
        } catch {
            Issue.record("expected ValidationError, got \(type(of: error))")
        }
    }

    // MARK: - Symmetric forwarder contract

    @Test("AndroidSwipeCommand.performSwipe is callable with the forwarder's argument shape")
    func androidSwipePerformContract() {
        // Compile-time pin: the forwarder calls into this signature.
        let _: (
            String,
            Int, Int,
            Int, Int,
            Int,
            AndroidDeviceController
        ) throws -> Void = AndroidSwipeCommand.performSwipe
    }

    // MARK: - Flag-surface parity

    @Test("ArgumentParser parses both top-level Swipe and IOSSimSwipeCommand with same flags")
    func flagSurfaceParses() throws {
        let argv = [
            "--start-x", "100",
            "--start-y", "200",
            "--end-x", "300",
            "--end-y", "400",
            "--duration", "0.5",
            "--delta", "20",
            "--pre-delay", "0.1",
            "--post-delay", "0.1",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
            "--json"
        ]
        let topLevel = try Swipe.parse(argv)
        let subCmd = try IOSSimSwipeCommand.parse(argv)

        #expect(try topLevel.resolvedCoordinates().startX == 100)
        #expect(try subCmd.resolvedCoordinates().startX == 100)
        #expect(try topLevel.resolvedCoordinates().endY == 400)
        #expect(try subCmd.resolvedCoordinates().endY == 400)
        #expect(topLevel.duration == 0.5)
        #expect(subCmd.duration == 0.5)
        #expect(topLevel.delta == 20)
        #expect(subCmd.delta == 20)
        #expect(topLevel.jsonOutput == true)
        #expect(subCmd.jsonOutput == true)
    }

    @Test("ArgumentParser parses --from/--to on top-level, iOS, and Android swipe")
    func pairFlagsParseAcrossSurfaces() throws {
        let argv = ["--from", "100,200", "--to", "300,400", "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0"]
        let topLevel = try Swipe.parse(argv)
        let subCmd = try IOSSimSwipeCommand.parse(argv)
        let android = try AndroidSwipeCommand.parse(["--from", "100,200", "--to", "300,400", "--device", "emulator-5554"])

        #expect(try topLevel.resolvedCoordinates() == SwipeCoordinates(startX: 100, startY: 200, endX: 300, endY: 400))
        #expect(try subCmd.resolvedCoordinates() == SwipeCoordinates(startX: 100, startY: 200, endX: 300, endY: 400))
        #expect(try android.resolvedCoordinates() == SwipeCoordinates(startX: 100, startY: 200, endX: 300, endY: 400))
    }

    @Test("ArgumentParser parses positional coordinate pairs")
    func positionalPairsParse() throws {
        let topLevel = try Swipe.parse(["100,200", "300,400", "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0"])
        let subCmd = try IOSSimSwipeCommand.parse(["100,200", "300,400", "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0"])

        #expect(try topLevel.resolvedCoordinates() == SwipeCoordinates(startX: 100, startY: 200, endX: 300, endY: 400))
        #expect(try subCmd.resolvedCoordinates() == SwipeCoordinates(startX: 100, startY: 200, endX: 300, endY: 400))
    }

    @Test("Swipe coordinate forms cannot be mixed or partial")
    func coordinateFormsRejectMixes() throws {
        #expect(throws: ValidationError.self) {
            _ = try SwipeCoordinateResolver.resolve(
                startX: 100, startY: nil, endX: nil, endY: nil,
                from: nil, to: nil,
                positional: []
            )
        }
        #expect(throws: ValidationError.self) {
            _ = try SwipeCoordinateResolver.resolve(
                startX: 100, startY: 200, endX: 300, endY: 400,
                from: CoordinatePair(x: 100, y: 200), to: CoordinatePair(x: 300, y: 400),
                positional: []
            )
        }
        #expect(throws: ValidationError.self) {
            _ = try SwipeCoordinateResolver.resolve(
                startX: nil, startY: nil, endX: nil, endY: nil,
                from: nil, to: nil,
                positional: []
            )
        }
    }
}
