// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import AndroidBackend
import ArgumentParser
import Foundation
import SimUseCore
import Testing

// Pins the contract between top-level `Gesture`,
// `IOSSimGestureCommand`, and `AndroidGestureCommand`.
@Suite("Gesture forwarder")
@MainActor
struct GestureForwarderTests {

    // MARK: - Validation parity

    @Test("Out-of-range screen-width rejected")
    func screenWidthRangeRejected() {
        do {
            try IOSSimGestureCommand.validateOptions(
                preset: .scrollUp,
                screenWidth: 5000, screenHeight: nil,
                duration: nil, delta: nil,
                scale: nil, angle: nil,
                centerX: nil, centerY: nil, radius: nil,
                steps: 10, stepMs: nil,
                preDelay: nil, postDelay: nil
            )
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("Screen width must be between"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("Out-of-range delta rejected")
    func deltaRangeRejected() {
        do {
            try IOSSimGestureCommand.validateOptions(
                preset: .scrollUp,
                screenWidth: nil, screenHeight: nil,
                duration: nil, delta: 500,
                scale: nil, angle: nil,
                centerX: nil, centerY: nil, radius: nil,
                steps: 10, stepMs: nil,
                preDelay: nil, postDelay: nil
            )
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("Delta must be between"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("--scale on a non-pinch preset rejected")
    func scaleOnNonPinchRejected() {
        do {
            try IOSSimGestureCommand.validateOptions(
                preset: .scrollUp,
                screenWidth: nil, screenHeight: nil,
                duration: nil, delta: nil,
                scale: 2.0, angle: nil,
                centerX: nil, centerY: nil, radius: nil,
                steps: 10, stepMs: nil,
                preDelay: nil, postDelay: nil
            )
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("--scale only applies to pinch presets"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    // MARK: - Android display-bounds enforcement

    @Test("pinch endpoints outside the display are rejected with the offending range")
    func pinchOffDisplayRejected() {
        let strokes = GesturePreset.pinchOut.strokes(
            screenWidth: 1080, screenHeight: 2400,
            scale: 3.0,
            centerX: 540, centerY: 1200,
            radius: 200
        )
        do {
            try AndroidGestureCommand.assertStrokesFitDisplay(
                strokes, width: 1080, height: 2400, preset: .pinchOut
            )
            Issue.record("expected CLIError")
        } catch let error as CLIError {
            #expect(error.localizedDescription.contains("pinch-out endpoints lie outside display"))
            #expect(error.localizedDescription.contains("1080x2400"))
            #expect(error.localizedDescription.contains("--scale or --radius"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("rotate sampling catches mid-arc display escape")
    func rotateOffDisplayRejected() {
        let strokes = GesturePreset.rotateCw.strokes(
            screenWidth: 1080, screenHeight: 2400,
            angle: 180,
            centerX: 100, centerY: 100,
            radius: 600
        )
        do {
            try AndroidGestureCommand.assertStrokesFitDisplay(
                strokes, width: 1080, height: 2400, preset: .rotateCw
            )
            Issue.record("expected CLIError")
        } catch let error as CLIError {
            #expect(error.localizedDescription.contains("rotate-cw"))
            #expect(error.localizedDescription.contains("--radius"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("centred pinch within the display passes the bounds check")
    func pinchOnDisplayAccepted() throws {
        let strokes = GesturePreset.pinchOut.strokes(
            screenWidth: 1080, screenHeight: 2400,
            scale: 2.5,
            centerX: 540, centerY: 1200,
            radius: 150
        )
        try AndroidGestureCommand.assertStrokesFitDisplay(
            strokes, width: 1080, height: 2400, preset: .pinchOut
        )
    }

    @Test("--angle on a pinch preset rejected")
    func angleOnPinchRejected() {
        do {
            try IOSSimGestureCommand.validateOptions(
                preset: .pinchOut,
                screenWidth: nil, screenHeight: nil,
                duration: nil, delta: nil,
                scale: nil, angle: 90,
                centerX: nil, centerY: nil, radius: nil,
                steps: 10, stepMs: nil,
                preDelay: nil, postDelay: nil
            )
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("--angle does not apply"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    // MARK: - Symmetric forwarder contract

    @Test("AndroidGestureCommand.performGesture is callable with the forwarder's argument shape")
    func androidGesturePerformContract() {
        let _: (
            String,
            GesturePreset,
            Double?, Double?,
            Double?,
            Double?, Double?, Double?, Double?, Double?,
            Double?, Double?,
            AndroidDeviceController
        ) throws -> Void = AndroidGestureCommand.performGesture
    }

    // MARK: - Flag-surface parity

    @Test("ArgumentParser parses both top-level Gesture and IOSSimGestureCommand with same flags")
    func flagSurfaceParses() throws {
        let argv = [
            "scroll-up",
            "--screen-width", "1080",
            "--screen-height", "2400",
            "--duration", "0.4",
            "--delta", "30",
            "--pre-delay", "0.1",
            "--post-delay", "0.1",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
            "--json",
        ]
        let topLevel = try Gesture.parse(argv)
        let subCmd = try IOSSimGestureCommand.parse(argv)

        #expect(topLevel.preset == .scrollUp)
        #expect(subCmd.preset == .scrollUp)
        #expect(topLevel.screenWidth == 1080)
        #expect(subCmd.screenWidth == 1080)
        #expect(topLevel.duration == 0.4)
        #expect(subCmd.duration == 0.4)
        #expect(topLevel.delta == 30)
        #expect(subCmd.delta == 30)
        #expect(topLevel.jsonOutput)
        #expect(subCmd.jsonOutput)
    }
}