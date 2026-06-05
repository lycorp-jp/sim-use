// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Opt-in stage timer for describe-ui perf investigation. Enabled only when
/// the environment variable `SIM_USE_PERF=1` is set. Writes to stderr so it
/// doesn't corrupt the command's JSON output on stdout.
///
/// Usage:
///   let t = PerfLog.start()
///   ... do work ...
///   t.stage("tree fetch")
///   ... more work ...
///   t.stage("walk")
///   t.finish("total")
@MainActor
public final class PerfLog {
    static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["SIM_USE_PERF"] == "1"
    }()

    private let startAbs: DispatchTime
    private var lastAbs: DispatchTime
    private var probeDurations: [Double] = []
    private var probeStageCounts: [String: Int] = [:]
    private var probeStageDurations: [String: Double] = [:]

    private init() {
        let now = DispatchTime.now()
        self.startAbs = now
        self.lastAbs = now
    }

    /// No-op no-allocation singleton when perf logging is off, so hot paths
    /// never pay the cost of instrumentation in production.
    static func start() -> PerfLog {
        isEnabled ? PerfLog() : disabled
    }
    private static let disabled = PerfLog()

    func stage(_ name: String) {
        guard PerfLog.isEnabled else { return }
        let now = DispatchTime.now()
        let sinceStart = ms(from: startAbs, to: now)
        let sinceLast = ms(from: lastAbs, to: now)
        lastAbs = now
        let paddedName = name.padding(toLength: 30, withPad: " ", startingAt: 0)
        emit("[PERF] \(paddedName) +\(fmt(sinceLast)) ms  (total \(fmt(sinceStart)) ms)")
    }

    func recordProbe(durationMs: Double, phase: String) {
        guard PerfLog.isEnabled else { return }
        probeDurations.append(durationMs)
        probeStageCounts[phase, default: 0] += 1
        probeStageDurations[phase, default: 0] += durationMs
    }

    private var outcomeCounts: [String: Int] = [:]
    func recordOutcome(_ tag: String) {
        guard PerfLog.isEnabled else { return }
        outcomeCounts[tag, default: 0] += 1
    }

    func finish(_ label: String = "total") {
        guard PerfLog.isEnabled else { return }
        let now = DispatchTime.now()
        let sinceStart = ms(from: startAbs, to: now)
        let paddedLabel = label.padding(toLength: 30, withPad: " ", startingAt: 0)
        emit("[PERF] \(paddedLabel) +\(fmt(ms(from: lastAbs, to: now))) ms  (wall \(fmt(sinceStart)) ms)")
        if !probeDurations.isEmpty {
            let sorted = probeDurations.sorted()
            let p50 = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int(Swift.Double(sorted.count) * 0.95))]
            let mx = sorted.last ?? 0
            let sum = probeDurations.reduce(0, +)
            emit("[PERF] probes count=\(probeDurations.count)  sum=\(fmt(sum)) ms  p50=\(fmt(p50))  p95=\(fmt(p95))  max=\(fmt(mx))")
            for (phase, count) in probeStageCounts.sorted(by: { $0.key < $1.key }) {
                let phaseSum = probeStageDurations[phase] ?? 0
                let avg = count > 0 ? phaseSum / Swift.Double(count) : 0
                emit("[PERF]   probes.\(phase) count=\(count)  sum=\(fmt(phaseSum)) ms  avg=\(fmt(avg)) ms")
            }
        }
        if !outcomeCounts.isEmpty {
            let sortedOutcomes = outcomeCounts.sorted(by: { $0.value > $1.value })
            let total = outcomeCounts.values.reduce(0, +)
            emit("[PERF] outcomes (total=\(total))")
            for (tag, count) in sortedOutcomes {
                let pct = Swift.Double(count) * 100 / Swift.Double(Swift.max(total, 1))
                emit("[PERF]   \(tag): \(count) (\(fmt(pct))%)")
            }
        }
    }

    private func fmt(_ v: Swift.Double) -> String {
        String(format: "%.2f", v)
    }

    private func ms(from: DispatchTime, to: DispatchTime) -> Double {
        Double(to.uptimeNanoseconds &- from.uptimeNanoseconds) / 1_000_000.0
    }

    private func emit(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}