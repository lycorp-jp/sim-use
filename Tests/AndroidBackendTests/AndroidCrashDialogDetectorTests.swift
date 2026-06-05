// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend
import SimUseCore

/// Crash-dialog detection is app-agnostic and keys off the locked
/// `android:` framework resource namespace, so these tests assert it fires
/// on the real AOSP ids, echoes the localized title, and refuses to
/// false-positive on look-alike ids minted by a third-party app.
final class AndroidCrashDialogDetectorTests: XCTestCase {

    private func node(
        _ resourceId: String,
        package: String = "android",
        className: String = "android.widget.Button",
        text: String = "",
        children: [ElementNode] = []
    ) -> ElementNode {
        ElementNode(
            resourceId: resourceId,
            package: package,
            className: className,
            text: text,
            contentDescription: "",
            boundsInScreen: ElementNode.Rect(left: 0, top: 0, right: 100, bottom: 100),
            children: children
        )
    }

    /// `App: android` crash dialog with the two buttons and a title.
    private func crashDialogRoot(title: String) -> ElementNode {
        node(
            "",
            className: "android.widget.FrameLayout",
            children: [
                node("android:id/alertTitle", className: "android.widget.TextView", text: title),
                node("android:id/aerr_app_info", text: "App info"),
                node("android:id/aerr_close", text: "Close app"),
            ]
        )
    }

    func testDetectsCrashDialogWithTitleEcho() {
        let signal = AndroidCrashDialogDetector.detect(root: crashDialogRoot(title: "LINE keeps stopping"))
        let s = try! XCTUnwrap(signal)
        XCTAssertEqual(s.kind, .appCrash)
        XCTAssertEqual(s.title, "LINE keeps stopping")
        XCTAssertEqual(s.matchedIds, ["android:id/aerr_app_info", "android:id/aerr_close"])
    }

    func testFiresOnEitherButtonAlone() {
        let onlyClose = node("", children: [node("android:id/aerr_close")])
        XCTAssertNotNil(AndroidCrashDialogDetector.detect(root: onlyClose))

        let onlyInfo = node("", children: [node("android:id/aerr_app_info")])
        XCTAssertNotNil(AndroidCrashDialogDetector.detect(root: onlyInfo))
    }

    func testNilTitleWhenAlertTitleAbsent() {
        let root = node("", children: [node("android:id/aerr_close")])
        let s = try! XCTUnwrap(AndroidCrashDialogDetector.detect(root: root))
        XCTAssertNil(s.title)
    }

    func testNoDialogReturnsNil() {
        // A plain screen plus a generic AlertDialog (alertTitle alone must
        // not trigger — it is not in the crash-dialog id set).
        let root = node(
            "com.app:id/root",
            package: "com.example.other",
            className: "android.widget.FrameLayout",
            children: [
                node("android:id/alertTitle", package: "android", className: "android.widget.TextView", text: "Delete?"),
                node("com.app:id/ok", package: "com.example.other", text: "OK"),
            ]
        )
        XCTAssertNil(AndroidCrashDialogDetector.detect(root: root))
    }

    func testThirdPartyLookAlikeIdDoesNotFalsePositive() {
        // An app that mints `aerr_close` in its OWN package namespace must
        // not be mistaken for the system dialog: the full resource id
        // differs and the short-name fallback is gated to package "android".
        let root = node(
            "",
            children: [
                node("com.evil.app:id/aerr_close", package: "com.evil.app"),
                node("com.evil.app:id/aerr_app_info", package: "com.evil.app"),
            ]
        )
        XCTAssertNil(AndroidCrashDialogDetector.detect(root: root))
    }

    func testShortNameFallbackUnderAndroidPackage() {
        // Defensive path: a bridge that strips the namespace still triggers
        // when the host package is "android".
        let root = node("", children: [node("aerr_close", package: "android")])
        XCTAssertNotNil(AndroidCrashDialogDetector.detect(root: root))
    }
}