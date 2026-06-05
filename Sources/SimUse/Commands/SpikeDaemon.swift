// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl
import iOSSimBackend
import SimUseCore

/// Internal spike command to validate long-lived FBSimulatorControl behavior
/// before committing to the daemon implementation (LINEIOS-216214).
///
/// Measures:
/// * one-off framework init cost
/// * per-call describe-ui latency when {{getSimulatorSet}} is re-entered many times in one process
/// * HID + accessibility interleaving
/// * optional manual pause to observe simulator-quit / reboot behavior
///
/// Run with {{SIM_USE_PERF=1}} to see the per-stage breakdown inside each call.
struct SpikeDaemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_spike-daemon",
        abstract: "Internal: probe long-lived FBSimulatorControl behavior.",
        shouldDisplay: false
    )

    @OptionGroup var device: DeviceOptions

    var simulatorUDID: String { device.resolved }

    mutating func validate() throws {
        try device.resolve()
    }


    @Option(name: .customLong("iterations"), help: "Number of describe-ui iterations.")
    var iterations: Int = 5

    @Option(name: .customLong("tap-x"), help: "X for the interleaved tap (default 100).")
    var tapX: Double = 100

    @Option(name: .customLong("tap-y"), help: "Y for the interleaved tap (default 100).")
    var tapY: Double = 100

    @Flag(name: .customLong("pause-for-invalidation"), help: "Pause 20s after main loop so you can quit / reboot the simulator, then retry.")
    var pauseForInvalidation: Bool = false

    func run() async throws {
        let logger = SimUseLogger()
        let err = StderrWriter()

        err.write("[spike] sim-use daemon feasibility probe — udid=\(simulatorUDID) iter=\(iterations)")

        // --- One-time framework init ---
        let tSetup = Clock()
        try await performGlobalSetup(logger: logger)
        err.write("[spike] performGlobalSetup: \(tSetup.elapsedMs) ms")

        // --- Multiple describe-ui calls in one process ---
        var describeTimings: [Double] = []
        for i in 1...iterations {
            let t = Clock()
            let data = try await AccessibilityFetcher.fetchAccessibilityInfoJSONData(
                for: simulatorUDID,
                logger: logger
            )
            let ms = t.elapsedMs
            describeTimings.append(ms)
            err.write(String(format: "[spike] describe-ui #%d: %.2f ms (%d bytes)", i, ms, data.count))
        }

        // --- One HID tap, then describe again ---
        let tHID1 = Clock()
        try await HIDInteractor.performHIDEvent(
            .tapAt(x: tapX, y: tapY),
            for: simulatorUDID,
            logger: logger
        )
        err.write(String(format: "[spike] HID tap #1 (incl. makeSession): %.2f ms", tHID1.elapsedMs))

        let tHID2 = Clock()
        try await HIDInteractor.performHIDEvent(
            .tapAt(x: tapX, y: tapY),
            for: simulatorUDID,
            logger: logger
        )
        err.write(String(format: "[spike] HID tap #2 (cached session): %.2f ms", tHID2.elapsedMs))

        let tPost = Clock()
        _ = try await AccessibilityFetcher.fetchAccessibilityInfoJSONData(
            for: simulatorUDID,
            logger: logger
        )
        err.write(String(format: "[spike] describe-ui post-HID: %.2f ms", tPost.elapsedMs))

        // --- Summary stats ---
        if let first = describeTimings.first {
            let rest = describeTimings.dropFirst()
            if let minRest = rest.min(), let maxRest = rest.max() {
                let avgRest = rest.reduce(0, +) / Double(rest.count)
                err.write(String(
                    format: "[spike] summary: first=%.2f ms  rest(%d) min=%.2f avg=%.2f max=%.2f",
                    first, rest.count, minRest, avgRest, maxRest
                ))
                let saving = first - avgRest
                err.write(String(
                    format: "[spike] inferred per-call init tax saved per warm call: ~%.2f ms",
                    saving
                ))
            }
        }

        // --- Optional invalidation probe ---
        if pauseForInvalidation {
            err.write("[spike] phase1: pausing 8s — shutdown the simulator now (describe-ui expected to fail after)")
            try await Task.sleep(nanoseconds: 8_000_000_000)

            let t1 = Clock()
            do {
                _ = try await AccessibilityFetcher.fetchAccessibilityInfoJSONData(
                    for: simulatorUDID,
                    logger: logger
                )
                err.write(String(format: "[spike] phase1 describe-ui: %.2f ms (unexpected success)", t1.elapsedMs))
            } catch {
                err.write(String(format: "[spike] phase1 describe-ui: %.2f ms expected-fail: %@",
                                 t1.elapsedMs,
                                 String(describing: error)))
            }

            err.write("[spike] phase2: pausing 15s — boot the simulator again; retrying describe-ui in a loop afterwards")
            try await Task.sleep(nanoseconds: 15_000_000_000)

            var recovered = false
            for attempt in 1...5 {
                let t = Clock()
                do {
                    _ = try await AccessibilityFetcher.fetchAccessibilityInfoJSONData(
                        for: simulatorUDID,
                        logger: logger
                    )
                    err.write(String(format: "[spike] phase2 attempt #%d: %.2f ms RECOVERED", attempt, t.elapsedMs))
                    recovered = true
                    break
                } catch {
                    err.write(String(format: "[spike] phase2 attempt #%d: %.2f ms still-fail: %@",
                                     attempt, t.elapsedMs, String(describing: error)))
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            if !recovered {
                err.write("[spike] VERDICT: same-process recovery FAILED after reboot — daemon must self-exit on invalidation")
            } else {
                err.write("[spike] VERDICT: same-process recovered after reboot — daemon could keep running")
            }
        }

        print("spike complete")
    }
}

private struct Clock {
    private let start = DispatchTime.now()
    var elapsedMs: Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }
}

private struct StderrWriter {
    func write(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}