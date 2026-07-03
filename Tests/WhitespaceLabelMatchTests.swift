// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
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

@Suite("Whitespace-tolerant label matching")
struct WhitespaceLabelMatchTests {
    @Test("multi-line AXLabel matches a space-joined --label query")
    func multilineLabelMatchesSpaceJoined() throws {
        // Real Flutter AXLabel carries newlines; the compact outline renders it
        // space-joined. The space-joined query must still resolve.
        let roots = [try makeElement(type: "StaticText", label: "드라이브\nOTT\n64%\nFIR", frame: (0, 100, 200, 80))]
        let point = try AccessibilityTargetResolver.resolveCenterPoint(
            roots: roots, query: .label("드라이브 OTT 64% FIR"))
        #expect(point.x == 100)
        #expect(point.y == 140)
    }

    @Test("exact single-line --label still matches (back-compat)")
    func exactSingleLineStillMatches() throws {
        let roots = [try makeElement(type: "Button", label: "퍼포먼스", frame: (0, 0, 80, 40))]
        let point = try AccessibilityTargetResolver.resolveCenterPoint(
            roots: roots, query: .label("퍼포먼스"))
        #expect(point.x == 40)
        #expect(point.y == 20)
    }

    @Test("exact --label match wins over a collapsed multi-line sibling")
    func exactMatchWinsBeforeCollapsedFallback() throws {
        let roots = [
            try makeElement(type: "Button", label: "A B", frame: (0, 0, 80, 40)),
            try makeElement(type: "Button", label: "A\nB", frame: (0, 100, 80, 40)),
        ]
        let point = try AccessibilityTargetResolver.resolveCenterPoint(
            roots: roots, query: .label("A B"))
        #expect(point.y == 20)
    }

    @Test("--label-contains matches a space-joined substring of a multi-line label")
    func labelContainsCollapsed() throws {
        let roots = [try makeElement(type: "Cell", label: "드라이브\nOTT\n64%\nFIR", frame: (10, 20, 100, 40))]
        let point = try AccessibilityTargetResolver.resolveCenterPoint(
            roots: roots, query: .labelContains("OTT 64%"))
        #expect(point.x == 60)
        #expect(point.y == 40)
    }

    @Test("collapsed empty --label-contains needle does not match everything")
    func emptyCollapsedContainsNeedleDoesNotMatchEverything() throws {
        let roots = [try makeElement(type: "Cell", label: "Anything", frame: (10, 20, 100, 40))]
        do {
            _ = try AccessibilityTargetResolver.resolveCenterPoint(
                roots: roots, query: .labelContains(" \n\t "))
            Issue.record("Expected all-whitespace contains query to remain not-found")
        } catch let error as ElementResolutionError {
            guard case .notFound = error else {
                Issue.record("Wrong case: \(error)")
                return
            }
        }
    }

    @Test("--value tolerates internal whitespace differences")
    func valueCollapsed() throws {
        let roots = [try makeElement(type: "StaticText", value: "1 234\nkm", frame: (0, 0, 100, 50))]
        let point = try AccessibilityTargetResolver.resolveCenterPoint(
            roots: roots, query: .value("1 234 km"))
        #expect(point.x == 50)
        #expect(point.y == 25)
    }

    @Test("collapseWhitespace collapses runs and trims; nil passes through")
    func collapseHelper() {
        #expect(SelectorTextMatcher.collapseWhitespace("  a\n\n b\tc  ") == "a b c")
        #expect(SelectorTextMatcher.collapseWhitespace("single") == "single")
        #expect(SelectorTextMatcher.collapseWhitespace(nil) == nil)
    }
}
