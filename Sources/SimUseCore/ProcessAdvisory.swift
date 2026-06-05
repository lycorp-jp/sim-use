// SPDX-License-Identifier: Apache-2.0
import Foundation

/// What a single command carries back about process-liveness changes.
/// `events` are edge-triggered (observed on this command); `pending` are
/// level-triggered (deaths that have not recovered yet), driving the
/// sticky "still on the home screen" reminder. Travels in the daemon
/// success envelope and the `--json` output under the `process` key.
public struct ProcessAdvisory: Codable, Equatable, Sendable {
    public let events: [ProcessEvent]
    public let pending: [ProcessEvent]

    public init(events: [ProcessEvent], pending: [ProcessEvent]) {
        self.events = events
        self.pending = pending
    }

    public var isEmpty: Bool { events.isEmpty && pending.isEmpty }
}

/// Renders a `ProcessAdvisory` into the human/agent-facing banner shown
/// at the top of `describe-ui` output (and prepended to action-verb
/// output). Pure; the loud/quiet/level shape is unit-tested.
///
/// Deliberately states facts, not verdicts: "disappeared / likely crash
/// or termination", never "crashed". Confirming the cause (reading
/// `.ips` / logcat) is the agent's job.
public enum ProcessAdvisoryRenderer {

    private static let rule = String(repeating: "=", count: 53)

    public static func banner(for advisory: ProcessAdvisory) -> String? {
        // High-confidence deaths/relaunches → loud banner.
        let loud = advisory.events.filter { $0.confidence == .high }
        if !loud.isEmpty {
            var lines = ["================ PROCESS DISAPPEARED ================"]
            for event in loud {
                lines.append(loudLine(for: event))
            }
            lines.append("Likely crash or termination, not a backgrounding. Verify before trusting subsequent actions.")
            lines.append(rule)
            return lines.joined(separator: "\n")
        }

        // Low-confidence idle changes → quiet single line(s).
        let quiet = advisory.events.filter { $0.confidence == .low }
        if !quiet.isEmpty {
            return quiet.map { event in
                "[i] \(event.bundleId)\(pidSuffix(event.pid)) is no longer running (observed after an idle gap; re-baselined). If unexpected, check crash reports."
            }.joined(separator: "\n")
        }

        // No new event, but unrecovered deaths remain → level sticky note.
        if !advisory.pending.isEmpty {
            return advisory.pending.map { event in
                "[!] \(event.bundleId)\(pidSuffix(event.pid)) has not relaunched since it disappeared. You may be acting against the home screen."
            }.joined(separator: "\n")
        }

        return nil
    }

    private static func loudLine(for event: ProcessEvent) -> String {
        switch event.kind {
        case .replaced:
            return "\(event.bundleId)\(pidSuffix(event.pid)) crashed and relaunched under a new process since the previous command."
        case .disappeared, .changedWhileIdle:
            return "\(event.bundleId)\(pidSuffix(event.pid)) was alive at the previous command and is GONE now."
        }
    }

    private static func pidSuffix(_ pid: Int?) -> String {
        guard let pid else { return "" }
        return " (pid \(pid))"
    }
}