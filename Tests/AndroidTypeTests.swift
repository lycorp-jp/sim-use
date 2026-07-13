// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Suite("Android Type Tests", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidTypeTests {
    @Test("type appends at the caret on the focused field")
    func typeAppendsAtCaret() async throws {
        try await AndroidE2E.launch(screen: "text-input")
        try await AndroidE2E.run("tap '#focus_button'")
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // The two types must follow in quick succession: `type` appends at the
        // caret, but only while the caret sits at the end — if the IME commits
        // and the field's selection resets between them (which happens once the
        // first type fully settles), the second type replaces instead. So keep
        // the gap short and do NOT wait for "abc" to settle. The generous final
        // timeout absorbs the a11y lag (the field holds "abcde" well before
        // describe-ui shows it, sometimes by several seconds on a loaded/cold
        // emulator).
        try await AndroidE2E.run("type \"abc\"")
        try await Task.sleep(nanoseconds: 800_000_000)
        try await AndroidE2E.run("type \"de\"")

        let ui = try await AndroidE2E.waitForOutline(timeout: 20) {
            AndroidE2E.trailingValue($0.label(resourceId: "text_echo")) == "abcde"
        }
        #expect(AndroidE2E.trailingValue(ui.label(resourceId: "text_echo")) == "abcde")
        #expect(AndroidE2E.trailingInt(ui.label(resourceId: "char_count")) == 5)
    }

    @Test("paste returns the documented Android clipboard error pointing at type")
    func pasteReturnsClipboardHint() async throws {
        try await AndroidE2E.launch(screen: "text-input")
        try await AndroidE2E.run("tap '#focus_button'")
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Android 10+ blocks background clipboard writes, so `paste` is
        // expected to fail with a clipboard_write_failed error whose hint
        // steers the caller to `type`. Asserting that error path is the
        // point — it is the contract agents rely on to self-correct.
        let result = try await AndroidE2E.run("paste \"hello world\" --json", allowFailure: true)
        #expect(result.exitCode != 0)
        #expect(result.output.contains("\"ok\":false"))
        #expect(result.output.contains("clipboard_write_failed"))
        #expect(result.output.lowercased().contains("type"))
    }
}
