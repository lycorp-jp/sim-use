// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import AndroidBackend
import ArgumentParser
import Foundation
import SimUseCore
import Testing

// Pins the contract between top-level `DescribeUI`,
// `IOSSimDescribeUICommand`, and `AndroidDescribeUICommand`. Mirrors
// `TapForwarderTests`.
@Suite("DescribeUI forwarder")
@MainActor
struct DescribeUIForwarderTests {

    // MARK: - Validation parity

    @Test("Negative --max-probes is rejected")
    func negativeMaxProbesRejected() {
        do {
            try IOSSimDescribeUICommand.validateOptions(
                maxProbes: -1,
                minCellSize: 14,
                seedCellWidth: 160,
                seedCellHeight: 80
            )
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("--max-probes must be non-negative"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("Zero --min-cell-size is rejected")
    func zeroMinCellSizeRejected() {
        do {
            try IOSSimDescribeUICommand.validateOptions(
                maxProbes: 100,
                minCellSize: 0,
                seedCellWidth: 160,
                seedCellHeight: 80
            )
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("--min-cell-size must be positive"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("Malformed --point is rejected at parse time")
    func malformedPointRejected() {
        // The `x,y` grammar lives on `CoordinatePair` (issue #25) —
        // ArgumentParser rejects a malformed value before validate().
        #expect(throws: (any Error).self) {
            _ = try IOSSimDescribeUICommand.parse([
                "--point", "not-a-point",
                "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
            ])
        }
    }

    @Test("Negative --point is rejected by shared validation")
    func negativePointRejected() {
        do {
            try IOSSimDescribeUICommand.validatePoint(CoordinatePair(x: -1, y: 5))
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("non-negative"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("Well-formed --point parses to coords, tolerating spaces")
    func validPointParses() throws {
        let parsed = try IOSSimDescribeUICommand.parse([
            "--point", "12.5, 36.0",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
        ])
        #expect(parsed.point?.x == 12.5)
        #expect(parsed.point?.y == 36.0)
    }

    // MARK: - Symmetric forwarder contract

    @Test("AndroidDescribeUICommand.performDescribeUI is callable with the forwarder's argument shape")
    func androidDescribePerformContract() {
        let _: (
            String,
            Bool,
            Bool,
            AndroidDeviceController
        ) throws -> DescribeUIResult = AndroidDescribeUICommand.performDescribeUI
    }

    // MARK: - Flag-surface parity

    @Test("ArgumentParser parses both top-level DescribeUI and IOSSimDescribeUICommand with same flags")
    func flagSurfaceParses() throws {
        let argv = [
            "--point", "100,200",
            "--max-probes", "500",
            "--min-cell-size", "20",
            "--seed-cell-width", "200",
            "--seed-cell-height", "100",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
            "--json"
        ]
        let topLevel = try DescribeUI.parse(argv)
        let subCmd = try IOSSimDescribeUICommand.parse(argv)

        #expect(topLevel.point == CoordinatePair(x: 100, y: 200))
        #expect(subCmd.point == CoordinatePair(x: 100, y: 200))
        #expect(topLevel.maxProbes == 500)
        #expect(subCmd.maxProbes == 500)
        #expect(topLevel.minCellSize == 20)
        #expect(subCmd.minCellSize == 20)
        #expect(topLevel.seedCellWidth == 200)
        #expect(subCmd.seedCellWidth == 200)
        #expect(topLevel.seedCellHeight == 100)
        #expect(subCmd.seedCellHeight == 100)
        #expect(topLevel.jsonOutput)
        #expect(subCmd.jsonOutput)
    }

    @Test("--include-offscreen is exposed only on the cross-platform surface")
    func includeOffscreenOnlyTopLevel() throws {
        // `--include-offscreen` is Android-only; the iOS sub-command
        // doesn't accept it. Confirm both surfaces match their design:
        // top-level parses it, IOSSim refuses it.
        let top = try DescribeUI.parse([
            "--include-offscreen",
            "--udid", "emulator-5554",
        ])
        #expect(top.includeOffscreen)

        do {
            _ = try IOSSimDescribeUICommand.parse([
                "--include-offscreen",
                "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
            ])
            Issue.record("expected IOSSimDescribeUICommand to reject --include-offscreen")
        } catch {
            // Expected: ArgumentParser surfaces an unknown-option error.
        }
    }
}