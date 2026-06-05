// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend

final class AndroidUDIDTests: XCTestCase {

    func testEmulatorSerialMatchesAndroid() {
        XCTAssertTrue(AndroidUDID.looksLikeAndroid("emulator-5554"))
        XCTAssertTrue(AndroidUDID.looksLikeAndroid("emulator-5556"))
    }

    func testRealDeviceSerialMatchesAndroid() {
        XCTAssertTrue(AndroidUDID.looksLikeAndroid("R5CT1ABCD12"))
        XCTAssertTrue(AndroidUDID.looksLikeAndroid("0123456789ABCDEF"))
    }

    func testIOSUDIDDoesNotMatchAndroid() {
        XCTAssertFalse(AndroidUDID.looksLikeAndroid("1A2B3C4D-1234-5678-90AB-CDEFCDEFCDEF"))
        XCTAssertFalse(AndroidUDID.looksLikeAndroid("12345678-1234-1234-1234-123456789ABC"))
    }

    func testIOSUDIDDetector() {
        XCTAssertTrue(AndroidUDID.looksLikeIOSUDID("00000000-0000-0000-0000-000000000000"))
        XCTAssertFalse(AndroidUDID.looksLikeIOSUDID("emulator-5554"))
        XCTAssertFalse(AndroidUDID.looksLikeIOSUDID(""))
    }

    func testEmptyAndWhitespaceRejected() {
        XCTAssertFalse(AndroidUDID.looksLikeAndroid(""))
        XCTAssertFalse(AndroidUDID.looksLikeAndroid("   "))
    }

    /// A typo like `--udid foo` should NOT be classified as Android.
    /// Today the cross-platform routing dispatches Android-shaped
    /// UDIDs straight to the adb pipeline, so a 3-char alphanumeric
    /// "name" reaches `adb -s foo devices` and produces an opaque
    /// failure 5+ seconds later. Refuse anything obviously typo-
    /// shaped (length < 4) so the iOS resolver gets a chance to
    /// emit its much friendlier "Simulator not found." error.
    func testRejectsShortTypoUdid() {
        XCTAssertFalse(AndroidUDID.looksLikeAndroid("foo"))
        XCTAssertFalse(AndroidUDID.looksLikeAndroid("a1"))
        XCTAssertFalse(AndroidUDID.looksLikeAndroid("abc"))
    }

    /// Pure-letter strings (no digits) are almost never real adb
    /// serials. `R5CT1ABCD12`, `7CKDU16C09042428`, `emulator-5554`
    /// all carry digits. Reject the no-digit case so dictionary-
    /// shaped typos like `--udid mycoolphone` route through the iOS
    /// resolver instead of adb.
    func testRejectsPureAlphaUdid() {
        XCTAssertFalse(AndroidUDID.looksLikeAndroid("foobar"))
        XCTAssertFalse(AndroidUDID.looksLikeAndroid("mycoolphone"))
        XCTAssertFalse(AndroidUDID.looksLikeAndroid("ABCDEFGH"))
    }

    /// `emulator-` prefix overrides the digit requirement — explicit
    /// regression guard, since the prefix shortcut runs before the
    /// digit check and must keep doing so.
    func testEmulatorPrefixOverridesDigitRule() {
        XCTAssertTrue(AndroidUDID.looksLikeAndroid("emulator-5554"))
        XCTAssertTrue(AndroidUDID.looksLikeAndroid("emulator-abc"))
    }

    /// Underscore-bearing serials (some emulator builds, vendor
    /// internal devices) still pass.
    func testUnderscoresAccepted() {
        XCTAssertTrue(AndroidUDID.looksLikeAndroid("R5CT_1ABCD12"))
    }
}