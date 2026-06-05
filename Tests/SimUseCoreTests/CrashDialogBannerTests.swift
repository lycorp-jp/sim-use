// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import Foundation
import Testing

@Suite("CrashDialogBanner — describe-ui crash-dialog banner")
struct CrashDialogBannerTests {

    @Test("With a title, the banner echoes it verbatim and reads as a crash dialog")
    func withTitle() {
        let signal = CrashDialogSignal(title: "LINE keeps stopping", matchedIds: ["android:id/aerr_close"])
        let text = CrashDialogBanner.banner(for: signal)
        #expect(text.contains("CRASH DIALOG DETECTED"))
        #expect(text.contains("\"LINE keeps stopping\""))
        #expect(text.contains("likely crashed"))
        #expect(text.contains("===="))
    }

    @Test("Without a title, the title clause is dropped but the banner still fires")
    func withoutTitle() {
        let signal = CrashDialogSignal(title: nil, matchedIds: ["android:id/aerr_app_info"])
        let text = CrashDialogBanner.banner(for: signal)
        #expect(text.contains("CRASH DIALOG DETECTED"))
        #expect(!text.contains("\"\""))
        #expect(!text.contains("("))
    }

    @Test("kind raw value is the app-agnostic, JSON-stable token")
    func kindWireValue() throws {
        let signal = CrashDialogSignal(title: nil, matchedIds: [])
        let data = try JSONEncoder().encode(signal)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("crash_dialog_detected"))
    }
}