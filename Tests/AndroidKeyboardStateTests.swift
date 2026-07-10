// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Suite("Android Keyboard State Tests", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidKeyboardStateTests {
    @Test("Keyboard reports hidden, then visible on focus, then hidden on unfocus")
    func keyboardVisibilityToggles() async throws {
        try await AndroidE2E.launch(screen: "text-input")

        // Clear any residual focus/IME from a prior screen first.
        try await AndroidE2E.run("tap '#unfocus_button'")
        #expect(try await AndroidE2E.waitForKeyboard(visible: false) == false)

        try await AndroidE2E.run("tap '#focus_button'")
        #expect(try await AndroidE2E.waitForKeyboard(visible: true) == true)

        try await AndroidE2E.run("tap '#unfocus_button'")
        #expect(try await AndroidE2E.waitForKeyboard(visible: false) == false)
    }
}
