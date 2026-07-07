// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
@testable import SimUseCore
import Foundation
import Testing

// MARK: - Test fixtures

private func makeElement(
    type: String? = nil,
    label: String? = nil,
    id: String? = nil,
    value: String? = nil,
    frame: (x: Double, y: Double, w: Double, h: Double)? = (0, 0, 100, 50),
    children: [[String: Any]] = []
) throws -> AccessibilityElement {
    var dict: [String: Any] = [:]
    if let type { dict["type"] = type }
    if let label { dict["AXLabel"] = label }
    if let id { dict["AXUniqueId"] = id }
    if let value { dict["AXValue"] = value }
    if let frame {
        dict["frame"] = ["x": frame.x, "y": frame.y, "width": frame.w, "height": frame.h]
    }
    if !children.isEmpty {
        dict["children"] = children
    }
    let data = try JSONSerialization.data(withJSONObject: dict)
    return try JSONDecoder().decode(AccessibilityElement.self, from: data)
}

private func decodeRoots(_ jsonObjects: [[String: Any]]) throws -> [AccessibilityElement] {
    let data = try JSONSerialization.data(withJSONObject: jsonObjects)
    return try JSONDecoder().decode([AccessibilityElement].self, from: data)
}

// MARK: - --label-contains

@Suite("AccessibilityTargetResolver --label-contains")
struct LabelContainsResolverTests {
    @Test("matches a substring inside a dynamic label")
    func substringMatches() throws {
        let roots: [AccessibilityElement] = [
            try makeElement(type: "Cell", label: "聊天, 7个新项目", frame: (10, 20, 100, 40)),
            try makeElement(type: "Cell", label: "联系人", frame: (10, 80, 100, 40)),
        ]
        let point = try AccessibilityTargetResolver.resolveCenterPoint(roots: roots, query: .labelContains("聊天,"))
        #expect(point.x == 60)
        #expect(point.y == 40)
    }

    @Test("substring match is case-sensitive")
    func caseSensitive() throws {
        let roots: [AccessibilityElement] = [
            try makeElement(type: "Button", label: "Settings"),
        ]
        #expect(throws: ElementResolutionError.self) {
            _ = try AccessibilityTargetResolver.resolveCenterPoint(roots: roots, query: .labelContains("settings"))
        }
    }

    @Test("element-type filter narrows the candidate pool")
    func elementTypeFilter() throws {
        let roots: [AccessibilityElement] = [
            try makeElement(type: "StaticText", label: "Save changes", frame: (0, 0, 50, 20)),
            try makeElement(type: "Button", label: "Save changes", frame: (10, 100, 100, 40)),
        ]
        let point = try AccessibilityTargetResolver.resolveCenterPoint(
            roots: roots,
            query: .labelContains("Save"),
            elementType: "Button"
        )
        #expect(point.x == 60)
        #expect(point.y == 120)
    }

    @Test("prefers the actionable match when one is actionable")
    func prefersActionable() throws {
        let roots: [AccessibilityElement] = [
            try makeElement(type: "StaticText", label: "Submit form", frame: (0, 0, 50, 20)),
            try makeElement(type: "Button", label: "Submit", frame: (10, 100, 100, 40)),
        ]
        let point = try AccessibilityTargetResolver.resolveCenterPoint(roots: roots, query: .labelContains("Submit"))
        #expect(point.y == 120)
    }

    @Test("multiple actionable matches throw with hint listing candidates")
    func multipleActionableMatches() throws {
        let roots: [AccessibilityElement] = [
            try makeElement(type: "Button", label: "Submit form", frame: (0, 0, 50, 20)),
            try makeElement(type: "Button", label: "Submit reply", frame: (10, 100, 100, 40)),
        ]
        do {
            _ = try AccessibilityTargetResolver.resolveCenterPoint(roots: roots, query: .labelContains("Submit"))
            Issue.record("Expected multipleMatches error")
        } catch let error as ElementResolutionError {
            guard case let .multipleMatches(count, kind, value, _, candidates) = error else {
                Issue.record("Wrong case: \(error)")
                return
            }
            #expect(count == 2)
            #expect(kind == "--label-contains")
            #expect(value == "Submit")
            #expect(candidates.contains("Submit form"))
            #expect(candidates.contains("Submit reply"))
            let hint = error.hint ?? ""
            #expect(hint.contains("--label-contains"))
            #expect(hint.contains("Submit"))
            #expect(hint.contains("Submit form"))
        }
    }

    @Test("not-found surfaces tree labels as candidates in hint")
    func notFoundCandidatesHint() throws {
        let roots: [AccessibilityElement] = [
            try makeElement(type: "Cell", label: "Home"),
            try makeElement(type: "Cell", label: "Profile"),
            try makeElement(type: "Cell", label: "Settings"),
        ]
        do {
            _ = try AccessibilityTargetResolver.resolveCenterPoint(roots: roots, query: .labelContains("__missing__"))
            Issue.record("Expected notFound error")
        } catch let error as ElementResolutionError {
            guard case let .notFound(_, value, candidates, _, _) = error else {
                Issue.record("Wrong case: \(error)")
                return
            }
            #expect(value == "__missing__")
            #expect(candidates == ["Home", "Profile", "Settings"])
            let hint = error.hint ?? ""
            #expect(hint.contains("__missing__"))
            #expect(hint.contains("'Home'"))
        }
    }
}

// MARK: - --label-regex

@Suite("AccessibilityTargetResolver --label-regex")
struct LabelRegexResolverTests {
    @Test("regex without anchors matches like contains")
    func unanchoredMatch() throws {
        let roots: [AccessibilityElement] = [
            try makeElement(type: "Cell", label: "Order #2024-04-30", frame: (0, 0, 100, 40)),
        ]
        let point = try AccessibilityTargetResolver.resolveCenterPoint(roots: roots, query: .labelRegex(pattern: #"Order\s+#\d{4}"#))
        #expect(point.x == 50)
        #expect(point.y == 20)
    }

    @Test("anchored regex demands exact match")
    func anchoredExactMatch() throws {
        let roots: [AccessibilityElement] = [
            try makeElement(type: "Cell", label: "Home", frame: (0, 0, 100, 40)),
            try makeElement(type: "Cell", label: "Home Tab", frame: (0, 50, 100, 40)),
        ]
        let point = try AccessibilityTargetResolver.resolveCenterPoint(roots: roots, query: .labelRegex(pattern: "^Home$"))
        #expect(point.y == 20)
    }

    @Test("ICU character classes are honoured")
    func icuCharacterClasses() throws {
        let roots: [AccessibilityElement] = [
            try makeElement(type: "Cell", label: "Alpha-9", frame: (0, 0, 100, 40)),
        ]
        let point = try AccessibilityTargetResolver.resolveCenterPoint(roots: roots, query: .labelRegex(pattern: #"^[A-Za-z]+-\d$"#))
        #expect(point.x == 50)
    }

    @Test("invalid regex pattern throws invalidPattern error")
    func invalidRegex() throws {
        let roots: [AccessibilityElement] = [try makeElement(type: "Cell", label: "anything")]
        do {
            _ = try AccessibilityTargetResolver.resolveCenterPoint(roots: roots, query: .labelRegex(pattern: "(unclosed"))
            Issue.record("Expected invalidPattern error")
        } catch let error as ElementResolutionError {
            guard case let .invalidPattern(kind, pattern, _) = error else {
                Issue.record("Wrong case: \(error)")
                return
            }
            #expect(kind == "--label-regex")
            #expect(pattern == "(unclosed")
        }
    }

    @Test("regex multipleMatches lists matched labels in hint")
    func multipleMatchHint() throws {
        let roots: [AccessibilityElement] = [
            try makeElement(type: "Button", label: "Reply 1"),
            try makeElement(type: "Button", label: "Reply 2"),
        ]
        do {
            _ = try AccessibilityTargetResolver.resolveCenterPoint(roots: roots, query: .labelRegex(pattern: "^Reply"))
            Issue.record("Expected multipleMatches error")
        } catch let error as ElementResolutionError {
            guard case let .multipleMatches(count, _, _, _, candidates) = error else {
                Issue.record("Wrong case: \(error)")
                return
            }
            #expect(count == 2)
            #expect(candidates == ["Reply 1", "Reply 2"])
        }
    }

    @Test("regex with element-type filter narrows pool")
    func regexWithElementType() throws {
        let roots: [AccessibilityElement] = [
            try makeElement(type: "StaticText", label: "Reply 1", frame: (0, 0, 50, 20)),
            try makeElement(type: "Button", label: "Reply 1", frame: (10, 100, 100, 40)),
        ]
        let point = try AccessibilityTargetResolver.resolveCenterPoint(
            roots: roots,
            query: .labelRegex(pattern: "^Reply"),
            elementType: "Button"
        )
        #expect(point.y == 120)
    }
}

// MARK: - frameFilter integration

@Suite("AccessibilityTargetResolver frameFilter")
struct FrameFilterIntegrationTests {
    /// The resolver expects a flattenable AX tree. We model the screen as one
    /// app root whose `frame` covers 0..400 x 0..800 and house all targets as
    /// children — same shape as a real iOS describe-ui payload.
    private func makeTree(targets: [[String: Any]]) throws -> [AccessibilityElement] {
        let app: [String: Any] = [
            "type": "Application",
            "AXLabel": "App",
            "frame": ["x": 0, "y": 0, "width": 400, "height": 800],
            "children": targets,
        ]
        let data = try JSONSerialization.data(withJSONObject: [app])
        return try JSONDecoder().decode([AccessibilityElement].self, from: data)
    }

    private func cellJSON(label: String, x: Double, y: Double, w: Double = 100, h: Double = 40) -> [String: Any] {
        [
            "type": "Cell",
            "AXLabel": label,
            "frame": ["x": x, "y": y, "width": w, "height": h],
        ]
    }

    @Test("frame filter narrows a multi-match label down to one element")
    func absFrameNarrowsMultiMatch() throws {
        let roots = try makeTree(targets: [
            cellJSON(label: "トーク", x: 16, y: 58),
            cellJSON(label: "トーク", x: 82, y: 792),
        ])
        let filter = try AccessibilityTargetResolver.FrameFilter(specs: ["minY=700"])
        let point = try AccessibilityTargetResolver.resolveCenterPoint(
            roots: roots, query: .label("トーク"), frameFilter: filter
        )
        #expect(point.y == 812)
    }

    @Test("relative frame filter resolves against the AX root frame")
    func relFrameResolvesAgainstRoot() throws {
        let roots = try makeTree(targets: [
            cellJSON(label: "Header", x: 0, y: 50),       // top region
            cellJSON(label: "Header", x: 0, y: 700),      // bottom region
        ])
        // Screen is 800 tall → 0.7r ≈ y=560 → only y=700 element passes.
        let filter = try AccessibilityTargetResolver.FrameFilter(specs: ["minY=0.7r"])
        let point = try AccessibilityTargetResolver.resolveCenterPoint(
            roots: roots, query: .label("Header"), frameFilter: filter
        )
        #expect(point.y == 720)
    }

    @Test("frame filter composes with --element-type")
    func frameComposesWithElementType() throws {
        let roots = try makeTree(targets: [
            ["type": "StaticText", "AXLabel": "Submit", "frame": ["x": 0, "y": 750, "width": 60, "height": 20]],
            ["type": "Button", "AXLabel": "Submit", "frame": ["x": 0, "y": 750, "width": 60, "height": 20]],
        ])
        let filter = try AccessibilityTargetResolver.FrameFilter(specs: ["minY=700"])
        let point = try AccessibilityTargetResolver.resolveCenterPoint(
            roots: roots, query: .label("Submit"), elementType: "Button", frameFilter: filter
        )
        // Both candidates share the frame; only Button survives the elementType filter.
        #expect(point.y == 760)
    }

    @Test("frame filter notFound carries the standard hint shape")
    func frameNotFoundHint() throws {
        let roots = try makeTree(targets: [
            cellJSON(label: "Submit", x: 0, y: 50),
        ])
        let filter = try AccessibilityTargetResolver.FrameFilter(specs: ["minY=700"])
        do {
            _ = try AccessibilityTargetResolver.resolveCenterPoint(
                roots: roots, query: .label("Submit"), frameFilter: filter
            )
            Issue.record("Expected notFound after frame filter eliminates the only match")
        } catch let error as ElementResolutionError {
            guard case .notFound = error else {
                Issue.record("Wrong case: \(error)")
                return
            }
            #expect(error.hint?.contains("--label") == true)
        }
    }

    @Test("relative frame filter uses the Application root when a non-app root comes first")
    func relFrameSkipsLeadingNonAppRoot() throws {
        // A keyboard-style window precedes the app root; 0.7r must
        // resolve against the app's 800-tall frame (y >= 560), not the
        // keyboard's 300-tall one (y >= 710, which would reject the
        // y=700 cell and fail the resolution).
        let json: [[String: Any]] = [
            [
                "type": "Window",
                "AXLabel": "Keyboard",
                "frame": ["x": 0, "y": 500, "width": 400, "height": 300],
            ],
            [
                "type": "Application",
                "AXLabel": "App",
                "frame": ["x": 0, "y": 0, "width": 400, "height": 800],
                "children": [
                    cellJSON(label: "Header", x: 0, y: 50),
                    cellJSON(label: "Header", x: 0, y: 700),
                ],
            ],
        ]
        let roots = try decodeRoots(json)
        let filter = try AccessibilityTargetResolver.FrameFilter(specs: ["minY=0.7r"])
        let point = try AccessibilityTargetResolver.resolveCenterPoint(
            roots: roots, query: .label("Header"), frameFilter: filter
        )
        #expect(point.y == 720)
    }

    @Test("relative frame filter without an AX root frame surfaces invalidFrame")
    func relWithoutScreenFrame() throws {
        // Build a tree where the first root has no frame at all.
        let json: [[String: Any]] = [[
            "type": "Application",
            "AXLabel": "App",
            "children": [
                ["type": "Cell", "AXLabel": "x", "frame": ["x": 0, "y": 700, "width": 50, "height": 20]],
            ],
        ]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let roots = try JSONDecoder().decode([AccessibilityElement].self, from: data)
        let filter = try AccessibilityTargetResolver.FrameFilter(specs: ["minY=0.5r"])
        do {
            _ = try AccessibilityTargetResolver.resolveCenterPoint(
                roots: roots, query: .label("x"), frameFilter: filter
            )
            Issue.record("Expected invalidFrame when relative bounds cannot be resolved")
        } catch let error as ElementResolutionError {
            guard case .invalidFrame = error else {
                Issue.record("Wrong case: \(error)")
                return
            }
        }
    }

    @Test("empty frame filter (nil) leaves the candidate pool untouched")
    func emptyFilterIsTransparent() throws {
        let roots = try makeTree(targets: [cellJSON(label: "Submit", x: 0, y: 100)])
        let point = try AccessibilityTargetResolver.resolveCenterPoint(
            roots: roots, query: .label("Submit"), frameFilter: nil
        )
        #expect(point.x == 50)
    }
}

// MARK: - HintProviding behaviour

@Suite("ElementResolutionError hint formatting")
struct ElementResolutionErrorHintTests {
    @Test("hint truncates beyond the cap and reports total")
    func truncationTag() {
        let many = (1...20).map { "label-\($0)" }
        let error = ElementResolutionError.notFound(
            kind: "--label-contains",
            value: "x",
            candidates: many,
            candidateKind: "labels",
            suggestedAlternative: nil
        )
        let hint = error.hint ?? ""
        #expect(hint.contains("top 10/20"))
        #expect(hint.contains("'label-1'"))
        #expect(!hint.contains("'label-20'"))
    }

    @Test("hint omits candidate list when empty")
    func emptyCandidates() {
        let error = ElementResolutionError.notFound(
            kind: "--label",
            value: "x",
            candidates: [],
            candidateKind: "labels",
            suggestedAlternative: nil
        )
        let hint = error.hint ?? ""
        #expect(hint == "pattern=--label 'x'")
    }

    @Test("--id failure whose value matches a label suggests --label")
    func idFailureSuggestsLabel() {
        let error = ElementResolutionError.notFound(
            kind: "--id",
            value: "地址",
            candidates: ["URL", "ReloadButton"],
            candidateKind: "ids",
            suggestedAlternative: "Did you mean `--label '地址'`? '地址' matches an accessibility label on this screen, not an id."
        )
        let description = error.errorDescription ?? ""
        #expect(description.contains("--label '地址'"))
        let hint = error.hint ?? ""
        #expect(hint.contains("ids"))
        #expect(hint.contains("'URL'"))
        #expect(hint.contains("Did you mean `--label '地址'`?"))
    }

    @Test("invalidFrame and invalidPattern do not produce hints")
    func nonHintingCases() {
        #expect(ElementResolutionError.invalidFrame(reason: "no frame").hint == nil)
        #expect(ElementResolutionError.invalidPattern(kind: "--label-regex", pattern: "(", reason: "x").hint == nil)
    }
}