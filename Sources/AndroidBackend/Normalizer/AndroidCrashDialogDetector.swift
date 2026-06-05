// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Detects the AOSP application-crash dialog ("<app> keeps stopping") in an
/// Android accessibility tree, purely from stable framework resource IDs —
/// with **no assumption about which app is under test**.
///
/// The crash dialog (`com.android.server.am.AppErrorDialog`) inflates its
/// buttons from `frameworks/base` `aerr_application.xml`, whose IDs
/// (`android:id/aerr_close`, `android:id/aerr_app_info`) have been stable
/// since Android 4.x and live in the locked `android:` resource namespace —
/// a third-party app cannot mint an id there, so matching them is
/// effectively false-positive-proof and locale-independent (unlike the
/// human-readable "keeps stopping" text, which is localized and therefore
/// only echoed, never used as a trigger).
public enum AndroidCrashDialogDetector {

    /// Fully-qualified resource IDs unique to the system crash dialog.
    /// Either one present in the tree is a sufficient trigger.
    static let triggerResourceIds: Set<String> = [
        "android:id/aerr_close",
        "android:id/aerr_app_info",
    ]

    /// Short names accepted only under the `android` host package, as a
    /// defensive fallback for bridges that strip the namespace prefix.
    private static let triggerShortNames: Set<String> = [
        "aerr_close",
        "aerr_app_info",
    ]

    /// Resource ID of the dialog's title view, used **only** to echo the
    /// on-screen text — never as a trigger (a generic AlertDialog id).
    private static let titleResourceId = "android:id/alertTitle"

    /// Returns a signal when the crash dialog is present in `root`, else
    /// `nil`. Walks the whole tree (including any secondary-window roots
    /// the bridge folds under its multi-window wrapper).
    public static func detect(root: ElementNode) -> CrashDialogSignal? {
        var matched: Set<String> = []
        var title: String?

        walk(root) { node in
            if triggerResourceIds.contains(node.resourceId) {
                matched.insert(node.resourceId)
            } else if node.package == "android", triggerShortNames.contains(node.resourceIdShortName) {
                matched.insert(node.resourceIdShortName)
            }
            if node.resourceId == titleResourceId, !node.text.isEmpty {
                title = node.text
            }
        }

        guard !matched.isEmpty else { return nil }
        return CrashDialogSignal(title: title, matchedIds: matched.sorted())
    }

    private static func walk(_ node: ElementNode, _ visit: (ElementNode) -> Void) {
        visit(node)
        for child in node.children { walk(child, visit) }
    }
}