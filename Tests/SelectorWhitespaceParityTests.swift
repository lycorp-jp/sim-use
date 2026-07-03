// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
@testable import AndroidBackend
@testable import SimUseCore
import Foundation
import Testing

private func makeElement(
    type: String? = nil,
    label: String? = nil,
    value: String? = nil,
    frame: (x: Double, y: Double, w: Double, h: Double)? = (0, 0, 100, 50)
) throws -> AccessibilityElement {
    var dict: [String: Any] = [:]
    if let type { dict["type"] = type }
    if let label { dict["AXLabel"] = label }
    if let value { dict["AXValue"] = value }
    if let frame {
        dict["frame"] = ["x": frame.x, "y": frame.y, "width": frame.w, "height": frame.h]
    }
    let data = try JSONSerialization.data(withJSONObject: dict)
    return try JSONDecoder().decode(AccessibilityElement.self, from: data)
}

private func makeEntry(
    at index: Int = 1,
    role: String = "Button",
    label: String = "",
    value: String? = nil
) -> Outline.Entry {
    Outline.Entry(
        aliases: .init(at: index),
        role: role,
        label: label,
        frame: .init(x: 100, y: index * 100, width: 300, height: 80),
        region: .init(kind: "Content"),
        states: [],
        uniqueId: nil,
        value: value,
        resourceId: nil,
        hint: nil
    )
}

// Pins the single canonical whitespace normal form (SelectorTextMatcher)
// shared by the iOS/Android outline renderers and the iOS/Android
// selector resolvers, and the cross-platform parity of the exact-first /
// collapsed-fallback matching policy built on it.
@Suite("Selector whitespace parity")
struct SelectorWhitespaceParityTests {

    // MARK: - Canonical collapse semantics

    @Test("canonical collapse folds all Unicode whitespace, not just \\n\\r\\t")
    func collapseFoldsUnicodeWhitespace() {
        #expect(SelectorTextMatcher.collapseWhitespace("a\u{00A0}b") == "a b") // NBSP
        #expect(SelectorTextMatcher.collapseWhitespace("a\u{3000}b") == "a b") // ideographic space
        #expect(SelectorTextMatcher.collapseWhitespace("a\u{2028}b") == "a b") // line separator
        #expect(SelectorTextMatcher.collapseWhitespace("a\r\nb") == "a b") // CRLF grapheme
        #expect(SelectorTextMatcher.collapseWhitespace(" \n\t ") == "")
    }

    @Test("iOS and Android outline renderers display the canonical matching form")
    func outlineRenderersUseCanonicalForm() {
        let nasty = "드라이브\nOTT\u{00A0}64%\r\n\tFIR"
        let canonical = SelectorTextMatcher.collapseWhitespace(nasty)
        #expect(OutlineFormatter.escapeAndTruncate(nasty, maxGraphemes: 60) == canonical)
        #expect(TruncationHelpers.escapeAndTruncate(nasty, maxGraphemes: 60) == canonical)
    }

    // MARK: - Android parity (the gap this suite was written to close)

    @Test("Android --label resolves a multi-line label from its space-joined outline form")
    func androidLabelCollapsedFallback() throws {
        let entries = [makeEntry(role: "Cell", label: "드라이브\nOTT\n64%\nFIR")]
        let hit = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(label: "드라이브 OTT 64% FIR"),
            entries: entries
        )
        #expect(hit.label == "드라이브\nOTT\n64%\nFIR")
    }

    @Test("Android --label-contains matches a space-joined substring of a multi-line label")
    func androidLabelContainsCollapsedFallback() throws {
        let entries = [makeEntry(role: "Cell", label: "드라이브\nOTT\n64%\nFIR")]
        let hit = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(labelContains: "OTT 64%"),
            entries: entries
        )
        #expect(hit.aliases.at == 1)
    }

    @Test("Android --value and --value-contains tolerate internal whitespace differences")
    func androidValueCollapsedFallback() throws {
        let entries = [makeEntry(role: "TextField", label: "distance", value: "1 234\nkm")]
        let byValue = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(value: "1 234 km"),
            entries: entries
        )
        #expect(byValue.value == "1 234\nkm")
        let byContains = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(valueContains: "234 km"),
            entries: entries
        )
        #expect(byContains.aliases.at == 1)
    }

    @Test("Android exact match still wins over a collapsed multi-line sibling")
    func androidExactMatchWins() throws {
        let entries = [
            makeEntry(at: 1, role: "Button", label: "A B"),
            makeEntry(at: 2, role: "Button", label: "A\nB"),
        ]
        let hit = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(label: "A B"),
            entries: entries
        )
        #expect(hit.aliases.at == 1)
    }

    @Test("Android all-whitespace --label-contains needle stays noMatch")
    func androidEmptyCollapsedNeedleStaysNoMatch() {
        let entries = [makeEntry(role: "Cell", label: "Anything")]
        #expect(throws: AndroidSelectorError.self) {
            _ = try AndroidSelectorResolver.resolve(
                selector: AndroidSelector(labelContains: " \n\t "),
                entries: entries
            )
        }
    }

    @Test("Android exact pass now end-trims like iOS (parity change)")
    func androidExactTrimsEnds() throws {
        let entries = [makeEntry(role: "Button", label: "Log in")]
        let hit = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(label: "Log in "),
            entries: entries
        )
        #expect(hit.label == "Log in")
    }

    // MARK: - Outline → selector round-trip (the load-bearing invariant)

    private func copiedLabel(fromOutline text: String, role: String) throws -> String {
        let line = try #require(
            text.components(separatedBy: "\n").first { $0.contains(role) },
            "no outline line for role \(role) in:\n\(text)"
        )
        let regex = try NSRegularExpression(pattern: "\"((?:[^\"\\\\]|\\\\.)*)\"")
        let range = NSRange(line.startIndex..., in: line)
        let match = try #require(
            regex.firstMatch(in: line, range: range),
            "no quoted label in outline line: \(line)"
        )
        let labelRange = try #require(Range(match.range(at: 1), in: line))
        return String(line[labelRange])
    }

    @Test("iOS: a label copied from the rendered outline resolves back via --label")
    func iosOutlineRoundTrip() throws {
        let element = try makeElement(
            type: "StaticText",
            label: "드라이브\nOTT\u{00A0}64%\nFIR",
            frame: (0, 100, 200, 80)
        )
        let outline = OutlineFormatter.render(tree: [element])
        let copied = try copiedLabel(fromOutline: outline.text, role: "StaticText")
        let point = try AccessibilityTargetResolver.resolveCenterPoint(
            roots: [element], query: .label(copied)
        )
        #expect(point.x == 100)
        #expect(point.y == 140)
    }

    @Test("known limitation: a truncated (>60 grapheme) outline label does not round-trip")
    func truncatedOutlineLabelDoesNotRoundTrip() throws {
        let longLabel = (1...20).map { "word\($0)" }.joined(separator: "\n")
        let element = try makeElement(type: "StaticText", label: longLabel, frame: (0, 100, 200, 80))
        let outline = OutlineFormatter.render(tree: [element])
        let copied = try copiedLabel(fromOutline: outline.text, role: "StaticText")
        #expect(copied.hasSuffix("…"), "expected the outline to truncate; got '\(copied)'")
        #expect(throws: ElementResolutionError.self) {
            _ = try AccessibilityTargetResolver.resolveCenterPoint(
                roots: [element], query: .label(copied)
            )
        }
    }

    // MARK: - --wait-timeout interplay

    @Test("poller retries a transient collapsed-fallback ambiguity until it clears")
    @MainActor
    func pollerRetriesTransientAmbiguity() async throws {
        let stale = try makeElement(type: "StaticText", label: "A\nB", frame: (0, 0, 100, 50))
        let settled = try makeElement(type: "StaticText", label: "A\tB", frame: (0, 100, 100, 50))
        var calls = 0
        let provider: AccessibilityPoller.RootsProvider = { _ in
            calls += 1
            return calls == 1 ? [stale, settled] : [settled]
        }
        let point = try await AccessibilityPoller.resolveWithPolling(
            query: .label("A B"),
            simulatorUDID: "TEST-PARITY",
            waitTimeout: 5,
            pollInterval: 0.02,
            rootsProvider: provider,
            logger: SimUseLogger(writeToStdErr: false)
        )
        #expect(calls >= 2)
        #expect(point.y == 125)
    }

    @Test("poller surfaces multipleMatches after the wait window for stable ambiguity")
    @MainActor
    func pollerReportsStableAmbiguity() async throws {
        let a = try makeElement(type: "StaticText", label: "A\nB", frame: (0, 0, 100, 50))
        let b = try makeElement(type: "StaticText", label: "A\tB", frame: (0, 100, 100, 50))
        let provider: AccessibilityPoller.RootsProvider = { _ in [a, b] }
        do {
            _ = try await AccessibilityPoller.resolveWithPolling(
                query: .label("A B"),
                simulatorUDID: "TEST-PARITY",
                waitTimeout: 0.1,
                pollInterval: 0.02,
                rootsProvider: provider,
                logger: SimUseLogger(writeToStdErr: false)
            )
            Issue.record("expected multipleMatches after the wait window")
        } catch let error as ElementResolutionError {
            guard case .multipleMatches = error else {
                Issue.record("expected multipleMatches, got \(error)")
                return
            }
        }
    }
}
