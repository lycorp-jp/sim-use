// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend

/// Focused tests for `AndroidScreenshotCommand.friendlier(_:)`.
/// The full screenshot path needs a live emulator / bridge to test
/// end-to-end; this file pins only the error-translation helper so
/// regressions on the message text are caught in unit time.
final class AndroidMediaCommandsTests: XCTestCase {

    /// The bridge's terse `screenshot_failed` should be re-wrapped
    /// with an actionable message that names the three real causes
    /// (framework rate limit, API <30, generic failure) and points
    /// at `record-video` for fast-capture loops.
    func testFriendlierUpgradesScreenshotFailed() {
        let raw = BridgeError.applicationError(
            status: "error",
            code: "screenshot_failed",
            message: "bridge bare error"
        )
        let upgraded = AndroidScreenshotCommand.friendlier(raw)
        let desc = upgraded.localizedDescription
        XCTAssertTrue(desc.contains("rate limit"), "got: \(desc)")
        XCTAssertTrue(desc.contains("record-video"))
    }

    /// Other bridge errors must pass through unchanged — friendlier
    /// is a targeted translator, not a catch-all.
    func testFriendlierPassesThroughUnrelatedErrors() {
        let raw = BridgeError.applicationError(
            status: "error",
            code: "no_active_window",
            message: "screen mid-transition"
        )
        let result = AndroidScreenshotCommand.friendlier(raw)
        // Same case shape, same code — message untouched.
        guard case BridgeError.applicationError(_, let code, let msg) = result else {
            XCTFail("expected applicationError; got \(result)")
            return
        }
        XCTAssertEqual(code, "no_active_window")
        XCTAssertEqual(msg, "screen mid-transition")
    }
}

/// Mirror of the screenshot translator tests: pin
/// `AndroidPasteCommand.friendlier(_:)` so regressions on the
/// agent-recovery copy are caught in unit time. The actual paste
/// path needs an emulator + focused field; this file only exercises
/// the error rewrite.
final class AndroidPasteFriendlierTests: XCTestCase {

    func testClipboardWriteFailedRewrites() {
        let raw = BridgeError.applicationError(
            status: "error",
            code: "clipboard_write_failed",
            message: "ClipboardManager.setPrimaryClip was denied"
        )
        let upgraded = AndroidPasteCommand.friendlier(raw)
        let desc = upgraded.localizedDescription
        // Names the underlying Android limitation so the agent
        // can map the failure to a known platform constraint.
        XCTAssertTrue(desc.contains("Android 10+"), "got: \(desc)")
        // Surfaces the recovery path concretely, including the verb
        // and its calling form — agents copy this near-verbatim.
        XCTAssertTrue(desc.contains("`sim-use type"), "got: \(desc)")
    }

    func testPasteUnsupportedRewrites() {
        let raw = BridgeError.applicationError(
            status: "error",
            code: "paste_unsupported",
            message: "Focused field does not support ACTION_PASTE"
        )
        let upgraded = AndroidPasteCommand.friendlier(raw)
        let desc = upgraded.localizedDescription
        XCTAssertTrue(desc.contains("ACTION_PASTE"), "got: \(desc)")
        XCTAssertTrue(desc.contains("`sim-use type"), "got: \(desc)")
    }

    /// Untranslated codes must pass through with their original
    /// case shape so callers can pattern-match — friendlier is a
    /// targeted translator, not a catch-all.
    func testFriendlierPassesThroughUnrelatedErrors() {
        let raw = BridgeError.applicationError(
            status: "error",
            code: "tap_failed",
            message: "no element under cursor"
        )
        let result = AndroidPasteCommand.friendlier(raw)
        guard case BridgeError.applicationError(_, let code, let msg) = result else {
            XCTFail("expected applicationError; got \(result)")
            return
        }
        XCTAssertEqual(code, "tap_failed")
        XCTAssertEqual(msg, "no element under cursor")
    }
}