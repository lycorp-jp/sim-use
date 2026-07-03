// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import ArgumentParser
import Foundation
import Testing

// Coverage for LINEIOS-216941: `paste` is now an accepted batch step
// verb. The default Cmd+V path is supported; `--via-menu` and `--stdin`
// are rejected with actionable messages. These tests exercise the
// parser surface — the actual HID + pbcopy plumbing has integration
// coverage gated on a real simulator (BatchPasteStepE2ETests).

@Suite("Batch — paste step parsing")
@MainActor
struct BatchPasteStepParsingTests {
    private func makeContext() -> BatchContext {
        BatchContext(
            simulatorUDID: "FAKE-UDID",
            axCachePolicy: .none,
            typeSubmissionMode: .chunked,
            typeChunkSize: 200
        )
    }

    private func parse(_ tokens: [String]) async throws -> [BatchPrimitive] {
        try await BatchStepParser.parseStepTokens(
            tokens,
            globalUDID: "FAKE-UDID",
            context: makeContext(),
            logger: SimUseLogger(writeToStdErr: false)
        )
    }

    @Test("`paste` is a recognised batch step kind")
    func pasteKindIsRecognised() {
        #expect(BatchStepKind(rawValue: "paste") == .paste)
    }

    @Test("`paste 'hello'` produces hostAction(pbcopy) + hidBarrier(Cmd+V)")
    func defaultPathPrimitives() async throws {
        let primitives = try await parse(["paste", "hello"])

        #expect(primitives.count == 2,
                "expected pbcopy + Cmd+V; got \(primitives.count) primitives")
        guard case .hostAction(let action) = primitives.first else {
            Issue.record("first primitive should be a hostAction (simctl pbcopy); got \(primitives)")
            return
        }
        #expect(action.label.contains("pbcopy"),
                "host action label should mention pbcopy; got '\(action.label)'")

        guard case .hidBarrier = primitives.last else {
            Issue.record("last primitive should be a hidBarrier (Cmd+V combo); got \(primitives)")
            return
        }
    }

    @Test("`paste --replace 'hello'` adds a Cmd+A barrier before Cmd+V")
    func replacePathPrimitives() async throws {
        let primitives = try await parse(["paste", "--replace", "hello"])

        #expect(primitives.count == 3,
                "expected pbcopy + Cmd+A + Cmd+V; got \(primitives.count) primitives")
        guard case .hostAction = primitives.first else {
            Issue.record("first primitive should be a hostAction; got \(primitives)")
            return
        }
        if case .hidBarrier = primitives[1] {
            // Cmd+A barrier as expected
        } else {
            Issue.record("second primitive should be a hidBarrier (Cmd+A combo); got \(primitives)")
        }
        if case .hidBarrier = primitives[2] {
            // Cmd+V barrier as expected
        } else {
            Issue.record("third primitive should be a hidBarrier (Cmd+V combo); got \(primitives)")
        }
    }

    @Test("`paste --via-menu` is rejected as a batch step")
    func viaMenuRejected() async throws {
        do {
            _ = try await parse([
                "paste", "--via-menu", "--target-id", "field", "hello"
            ])
            Issue.record("expected --via-menu to be rejected as a batch step")
        } catch {
            // ArgumentParser's `ValidationError` does not surface its
            // message through `localizedDescription`; the existing test
            // suite uses `String(describing:)` (TapValidationTests).
            let message = String(describing: error).lowercased()
            #expect(message.contains("via-menu"),
                    "error should mention --via-menu; got: \(String(describing: error))")
        }
    }

    @Test("`paste --stdin` is rejected as a batch step")
    func stdinRejected() async throws {
        do {
            _ = try await parse(["paste", "--stdin"])
            Issue.record("expected --stdin to be rejected as a batch step")
        } catch {
            let message = String(describing: error).lowercased()
            #expect(message.contains("stdin"),
                    "error should mention --stdin; got: \(String(describing: error))")
        }
    }

    @Test("`paste` with no text and no --file is rejected")
    func emptyInputRejected() async throws {
        do {
            _ = try await parse(["paste"])
            Issue.record("expected empty paste to be rejected")
        } catch {
            // Either Paste's own validate() catches it, or BatchConvertible does;
            // either way the error reaches the user.
        }
    }

    @Test("`paste` accepts unicode + emoji text")
    func unicodePayload() async throws {
        let primitives = try await parse(["paste", "日本語 你好 🎉"])
        #expect(primitives.count == 2)
        guard case .hostAction(let action) = primitives.first else {
            Issue.record("first primitive should be a hostAction; got \(primitives)")
            return
        }
        // Label encodes the byte count — for unicode/emoji that's > the
        // visible character count, so use that as a sanity check that
        // the right text reached the action.
        let utf8Count = "日本語 你好 🎉".utf8.count
        #expect(action.label.contains("\(utf8Count)"),
                "expected pbcopy label to mention the full \(utf8Count)-byte payload; got '\(action.label)'")
    }

    @Test("`swipe --from x,y --to x,y` is accepted as a batch step")
    func swipePairCoordinates() async throws {
        let primitives = try await parse(["swipe", "--from", "10,20", "--to", "30,40"])
        #expect(primitives.count == 1)
        guard case .hidMergeable = primitives[0] else {
            Issue.record("swipe should produce one mergeable HID primitive; got \(primitives)")
            return
        }
    }

    @Test("positional `swipe x,y x,y` is accepted as a batch step")
    func swipePositionalCoordinates() async throws {
        let primitives = try await parse(["swipe", "10,20", "30,40"])
        #expect(primitives.count == 1)
        guard case .hidMergeable = primitives[0] else {
            Issue.record("swipe should produce one mergeable HID primitive; got \(primitives)")
            return
        }
    }
}
