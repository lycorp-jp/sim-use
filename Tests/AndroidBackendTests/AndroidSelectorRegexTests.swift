// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend
import SimUseCore

final class AndroidSelectorRegexTests: XCTestCase {

    private func sampleEntries() -> [Outline.Entry] {
        [
            Outline.Entry(
                aliases: .init(at: 1),
                role: "TextField",
                label: "Email",
                frame: .init(x: 0, y: 0, width: 100, height: 40),
                region: .init(kind: "Content"),
                states: [],
                value: "wei.wang@example.com",
                resourceId: "email_field",
                hint: "Email"
            ),
            Outline.Entry(
                aliases: .init(at: 2),
                role: "TextField",
                label: "Phone",
                frame: .init(x: 0, y: 60, width: 100, height: 40),
                region: .init(kind: "Content"),
                states: [],
                value: "090-1234-5678",
                resourceId: "phone_field",
                hint: "Phone"
            ),
            Outline.Entry(
                aliases: .init(at: 3),
                role: "Button",
                label: "Submit",
                frame: .init(x: 0, y: 120, width: 100, height: 40),
                region: .init(kind: "Content"),
                states: [],
                resourceId: "submit_button"
            ),
        ]
    }

    func testLabelRegexMatchesAnchored() throws {
        let entries = sampleEntries()
        let match = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(labelRegex: "^Sub"),
            entries: entries
        )
        XCTAssertEqual(match.aliases.at, 3)
    }

    func testValueRegexMatchesEmail() throws {
        let entries = sampleEntries()
        let match = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(valueRegex: "\\w+@example\\.com"),
            entries: entries
        )
        XCTAssertEqual(match.aliases.at, 1)
    }

    func testInvalidRegexErrors() {
        let entries = sampleEntries()
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(labelRegex: "([invalid"),
            entries: entries
        )) { error in
            if case AndroidSelectorError.invalidRegex = error { return }
            XCTFail("Expected invalidRegex, got \(error)")
        }
    }

    func testAndCombineNarrowsMultipleMatches() throws {
        let entries = sampleEntries()
        // labelContains "" alone is ambiguous, plus elementType narrows to Button.
        let match = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(labelContains: "Su", elementType: "Button"),
            entries: entries
        )
        XCTAssertEqual(match.aliases.at, 3)
    }

    func testValueExactMatch() throws {
        let entries = sampleEntries()
        let match = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(value: "090-1234-5678"),
            entries: entries
        )
        XCTAssertEqual(match.aliases.at, 2)
    }

    func testLabelContainsIsCaseSensitive() {
        // `--label-contains` is case-sensitive (mirrors iOS, mirrors the
        // documented help text). Earlier releases used
        // `localizedCaseInsensitiveContains` so "SUBMIT" matched
        // "Submit" on Android only — a silent cross-platform gap. The
        // resolver now misses on case mismatch; callers wanting
        // case-insensitive substring matching pass a `(?i)…` regex
        // through `--label-regex`.
        let entries = sampleEntries()
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(labelContains: "SUBMIT"),
            entries: entries
        )) { error in
            if case AndroidSelectorError.noMatch = error { return }
            XCTFail("Expected noMatch on case mismatch, got \(error)")
        }
    }

    func testLabelRegexEnablesCaseInsensitiveOptIn() throws {
        // The escape hatch when case-insensitive substring matching is
        // wanted — ICU regex `(?i)` flag. Keeps the default selector
        // strict while preserving an opt-in path.
        let entries = sampleEntries()
        let match = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(labelRegex: "(?i)submit"),
            entries: entries
        )
        XCTAssertEqual(match.aliases.at, 3)
    }

    func testResourceIdAndElementTypeCombined() throws {
        let entries = sampleEntries()
        let match = try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(id: "email_field", elementType: "TextField"),
            entries: entries
        )
        XCTAssertEqual(match.aliases.at, 1)
    }

    func testIdMismatchedWithElementTypeProducesNoMatch() {
        let entries = sampleEntries()
        XCTAssertThrowsError(try AndroidSelectorResolver.resolve(
            selector: AndroidSelector(id: "email_field", elementType: "Button"),
            entries: entries
        )) { error in
            if case AndroidSelectorError.noMatch = error { return }
            XCTFail("Expected noMatch, got \(error)")
        }
    }
}