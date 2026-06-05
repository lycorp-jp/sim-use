// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A point-in-time set of live "hosted app" processes on a device,
/// keyed by pid. On iOS this is parsed from `launchctl list`
/// (`UIKitApplication:` rows); on Android from `adb shell` process
/// listing. Extensions / system daemons are filtered out by the probe
/// before they reach here, so the values are real app bundle / package
/// ids.
public struct AppSnapshot: Equatable, Sendable {
    public let appsByPid: [Int: String]

    public init(appsByPid: [Int: String]) {
        self.appsByPid = appsByPid
    }

    public var pids: Set<Int> { Set(appsByPid.keys) }

    /// Liveness of a specific bundle/package id in this snapshot.
    public func liveness(ofBundleId bundleId: String) -> LivenessState {
        if let pid = appsByPid.first(where: { $0.value == bundleId })?.key {
            return .alive(pid: pid)
        }
        return .dead
    }
}

/// Pure liveness verdict for a bundle in an `AppSnapshot`. The
/// foreground-vs-background distinction is *not* decided here (it needs
/// foreground knowledge the liveness probe does not carry); the
/// `app-state` command layers that on top when it can.
public enum LivenessState: Equatable, Sendable {
    case alive(pid: Int)
    case dead
}

public enum ProcessEventKind: String, Codable, Equatable, Sendable {
    /// A hosted-app pid that was alive at the previous command is gone,
    /// and the bundle has not relaunched. Strong crash/termination signal.
    case disappeared
    /// Same bundle, different pid — the process was replaced
    /// (crash-and-relaunch) since the previous command.
    case replaced
    /// A process-set change observed only after an idle gap longer than
    /// the active window. Cannot be confidently attributed to active
    /// driving (likely an out-of-band kill), so it is surfaced quietly.
    case changedWhileIdle = "changed_while_idle"
}

public enum ProcessEventConfidence: String, Codable, Equatable, Sendable {
    /// Observed within the active window — attributable to recent driving.
    case high
    /// Observed after an idle gap — low attribution confidence.
    case low
}

/// A single process-liveness event surfaced to the agent. Never a
/// verdict ("crash") — a fact plus a confidence band. Confirming
/// crash-vs-clean-kill (reading `.ips` / logcat) is the agent's job.
public struct ProcessEvent: Codable, Equatable, Sendable {
    public let kind: ProcessEventKind
    public let bundleId: String
    public let pid: Int?
    public let confidence: ProcessEventConfidence

    public init(kind: ProcessEventKind, bundleId: String, pid: Int?, confidence: ProcessEventConfidence) {
        self.kind = kind
        self.bundleId = bundleId
        self.pid = pid
        self.confidence = confidence
    }
}

/// Cross-command crash/termination detector.
///
/// Pure state machine: it never performs I/O. The daemon owns the
/// platform probe (`launchctl` / `adb`), calls it once per command, and
/// feeds the resulting `AppSnapshot` to `evaluate`. Keeping the tracker
/// I/O-free makes the detection logic fully unit-testable with synthetic
/// snapshot sequences (issue #81).
///
/// The crash signal is **process liveness** (a pid that was alive is
/// gone), never foreground identity — so legitimate backgrounding never
/// false-fires, and the false-positive-prone idle-gap case is downgraded
/// to a quiet, unlatched `changedWhileIdle`.
public final class ProcessLivenessTracker {
    /// Deaths observed within this window of the previous command count
    /// as high-confidence; beyond it they are `changedWhileIdle`.
    public let activeWindow: TimeInterval

    /// Bundle-id prefixes excluded from event generation. System
    /// processes (permission prompts, share sheets, etc.) appear and
    /// disappear as normal OS behaviour; tracking them produces
    /// persistent false-positive "has not relaunched" warnings.
    public static let systemBundlePrefixes: [String] = [
        "com.apple.",
        "com.google.",
        "com.android.",
    ]

    public private(set) var previous: AppSnapshot?
    public private(set) var previousAt: Date?
    /// Bundles with an unrecovered high-confidence death, keyed by bundle
    /// id. Drives the level-triggered "still on the home screen" note.
    public private(set) var pending: [String: ProcessEvent]

    public init(activeWindow: TimeInterval = 120) {
        self.activeWindow = activeWindow
        self.previous = nil
        self.previousAt = nil
        self.pending = [:]
    }

    /// Diff `current` against the previous snapshot, gate by elapsed
    /// time, update internal state, and return any events. The first
    /// call only baselines and returns nothing.
    @discardableResult
    public func evaluate(current: AppSnapshot, now: Date) -> [ProcessEvent] {
        defer {
            previous = current
            previousAt = now
        }

        guard let prev = previous, let prevAt = previousAt else {
            return []  // first observation: baseline only
        }

        let confidence: ProcessEventConfidence =
            now.timeIntervalSince(prevAt) <= activeWindow ? .high : .low

        var events: [ProcessEvent] = []
        // A pid present before and absent now = that process is gone.
        let gone = prev.appsByPid.filter { current.appsByPid[$0.key] == nil }
        let liveBundles = Set(current.appsByPid.values)
        for (pid, bundleId) in gone {
            if Self.systemBundlePrefixes.contains(where: { bundleId.hasPrefix($0) }) {
                continue
            }
            let kind: ProcessEventKind
            if confidence == .low {
                kind = .changedWhileIdle
            } else {
                kind = liveBundles.contains(bundleId) ? .replaced : .disappeared
            }
            let event = ProcessEvent(kind: kind, bundleId: bundleId, pid: pid, confidence: confidence)
            events.append(event)
            // Latch only unrecovered, high-confidence disappearances so
            // the level note keeps reminding while still on the home
            // screen. `replaced` is already back; idle changes are quiet.
            if kind == .disappeared {
                pending[bundleId] = event
            }
        }

        // Recovery: clear any latched death whose bundle is alive again.
        for bundleId in pending.keys where liveBundles.contains(bundleId) {
            pending[bundleId] = nil
        }

        return events
    }

    /// Re-baseline to `current` and clear the latch. This is the single
    /// primitive behind `app-state --reset`: acknowledging an accepted
    /// crash, establishing a baseline after an external launch, or
    /// attaching to an already-running app.
    public func reset(to current: AppSnapshot, now: Date) {
        previous = current
        previousAt = now
        pending.removeAll()
    }
}