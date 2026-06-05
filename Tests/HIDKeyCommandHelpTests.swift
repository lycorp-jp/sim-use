// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import XCTest

/// Guards the cross-platform error message for `key` / `key-sequence` /
/// `key-combo` when run against an Android UDID. We assert *structure*
/// (verb name, UDID, redirect targets) rather than the exact wording so
/// minor copy edits don't break the test, but a missing redirect would.
final class HIDKeyCommandHelpTests: XCTestCase {

    func testMessageEmbedsVerbName() {
        for verb in ["key", "key-sequence", "key-combo"] {
            let message = HIDKeyCommandHelp.androidUnsupportedMessage(verb: verb, udid: "emulator-5554")
            XCTAssertTrue(message.contains("`\(verb)`"), "message must quote the verb '\(verb)' in backticks; got: \(message)")
        }
    }

    func testMessageEmbedsUDID() {
        let message = HIDKeyCommandHelp.androidUnsupportedMessage(verb: "key", udid: "emulator-5554")
        XCTAssertTrue(message.contains("emulator-5554"), "UDID must appear in the error so the user can copy-paste the suggested command")
    }

    func testMessageRedirectsToAndroidNativeVerbs() {
        let message = HIDKeyCommandHelp.androidUnsupportedMessage(verb: "key", udid: "emulator-5554")
        // The three Android-native verbs we redirect users to. Catch if
        // someone removes a redirect without updating the help.
        XCTAssertTrue(message.contains("sim-use button"), "redirect to `button` is missing")
        XCTAssertTrue(message.contains("sim-use type"), "redirect to `type` is missing")
        XCTAssertTrue(message.contains("sim-use paste"), "redirect to `paste` is missing")
    }

    func testMessageMentionsEnterAlternative() {
        let message = HIDKeyCommandHelp.androidUnsupportedMessage(verb: "key", udid: "emulator-5554")
        // The most common reason to reach for `key` on Android is Enter
        // (HID 40). Spell out the workaround so users don't have to ask.
        XCTAssertTrue(message.contains("Enter"), "Enter workaround must be mentioned")
        XCTAssertTrue(message.contains("\\n"), "should reference the `\\n` escape in type")
    }
}