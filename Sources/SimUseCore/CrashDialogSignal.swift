// SPDX-License-Identifier: Apache-2.0
import Foundation

/// An app-agnostic signal that the Android system is currently showing an
/// "application has crashed" dialog (the AOSP `AppErrorDialog`, rendered as
/// "<app> keeps stopping"). Detected purely from stable framework resource
/// IDs in the accessibility tree — it makes **no assumption about which app
/// is under test**, only that a crash dialog is on screen right now.
///
/// Surfaced alongside `describe-ui`: a banner above the outline (the
/// default text surface) and, in `--json`, under `data.crashDialog`. It is
/// a timing-insensitive fast path that complements the daemon's
/// process-liveness `ProcessAdvisory` — the two are independent and either
/// one alone is a sufficient crash signal (logical OR). Like the liveness
/// advisory it states a **fact, not a verdict**: confirming the cause
/// (logcat / tombstone) is the agent's job.
public struct CrashDialogSignal: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        /// AOSP application-crash dialog (`aerr_*` ids, "keeps stopping").
        case appCrash = "crash_dialog_detected"
    }

    public let kind: Kind
    /// The dialog's on-screen title, echoed verbatim when present (e.g.
    /// "LINE keeps stopping"). Reported for the agent's benefit only; the
    /// tool deliberately does *not* parse an app identity out of it.
    public let title: String?
    /// Which framework resource IDs matched, for debuggability.
    public let matchedIds: [String]

    public init(kind: Kind = .appCrash, title: String?, matchedIds: [String]) {
        self.kind = kind
        self.title = title
        self.matchedIds = matchedIds
    }
}

/// Renders a `CrashDialogSignal` into the banner shown above the
/// `describe-ui` outline. House style mirrors `ProcessAdvisoryRenderer`:
/// an ASCII rule block, no emoji, stating a fact plus a soft inference and
/// never a hard "crashed" verdict, so the two crash surfaces read alike.
public enum CrashDialogBanner {

    private static let rule = String(repeating: "=", count: 53)

    public static func banner(for signal: CrashDialogSignal) -> String {
        var lines = ["=============== CRASH DIALOG DETECTED ==============="]
        if let title = signal.title, !title.isEmpty {
            lines.append("An Android system app-crash dialog is on screen (\"\(title)\").")
        } else {
            lines.append("An Android system app-crash dialog is on screen.")
        }
        lines.append("The app under test likely crashed; you are now looking at a system dialog, not the app.")
        lines.append("Verify before trusting subsequent actions.")
        lines.append(rule)
        return lines.joined(separator: "\n")
    }
}