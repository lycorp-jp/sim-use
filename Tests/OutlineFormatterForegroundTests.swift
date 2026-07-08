// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

private func decodeTree(_ json: String) throws -> [AccessibilityElement] {
    try JSONDecoder().decode([AccessibilityElement].self, from: Data(json.utf8))
}

/// A SpringBoard-shaped tree whose Application root carries a stale app
/// label — the shape issue #81 reports right after a crash.
private let staleLabelTree = #"""
[
  {
    "type": "Application",
    "AXLabel": "LINE Dev",
    "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
    "children": [
      { "type": "Button", "AXLabel": "Fitness", "frame": { "x": 10, "y": 200, "width": 60, "height": 60 } }
    ]
  }
]
"""#

private let emptyLabelTree = #"""
[
  {
    "type": "Application",
    "AXLabel": "",
    "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
    "children": [
      { "type": "Button", "AXLabel": "Fitness", "frame": { "x": 10, "y": 200, "width": 60, "height": 60 } }
    ]
  }
]
"""#

@Suite("OutlineFormatter — foreground reconciliation")
struct OutlineFormatterForegroundTests {

    @Test("Orientation tag appends to the header; nil keeps the legacy form")
    func orientationTagInHeader() throws {
        let tagged = OutlineFormatter.render(
            tree: try decodeTree(staleLabelTree),
            orientationTag: "landscape-right"
        )
        #expect(tagged.text.hasPrefix("App: LINE Dev  402x874  (landscape-right)\n"))

        let untagged = OutlineFormatter.render(tree: try decodeTree(staleLabelTree))
        #expect(untagged.text.hasPrefix("App: LINE Dev  402x874\n"))
    }

    @Test("Resolved SpringBoard bundle overrides a stale app label in the header")
    func springBoardOverridesStaleLabel() throws {
        let outline = OutlineFormatter.render(
            tree: try decodeTree(staleLabelTree),
            foregroundBundleId: "com.apple.springboard"
        )
        #expect(outline.appLabel == "SpringBoard")
        #expect(outline.text.hasPrefix("App: SpringBoard  402x874"))
    }

    @Test("Empty root label resolves to the foreground bundle, never blank")
    func emptyLabelResolvesToShell() throws {
        let outline = OutlineFormatter.render(
            tree: try decodeTree(emptyLabelTree),
            foregroundBundleId: "com.apple.springboard"
        )
        #expect(outline.appLabel == "SpringBoard")
        #expect(outline.text.hasPrefix("App: SpringBoard  402x874"))
    }

    @Test("Omitting foregroundBundleId preserves the legacy tree-derived label")
    func legacyBehaviorPreserved() throws {
        // Backward-compatibility: existing callers/tests that don't pass
        // a foreground bundle must see the unchanged tree-derived header.
        let outline = OutlineFormatter.render(tree: try decodeTree(staleLabelTree))
        #expect(outline.appLabel == "LINE Dev")
        #expect(outline.text.hasPrefix("App: LINE Dev  402x874"))
    }

    @Test("Real foreground app keeps its label")
    func realAppKeepsLabel() throws {
        let outline = OutlineFormatter.render(
            tree: try decodeTree(staleLabelTree),
            foregroundBundleId: "com.example.app"
        )
        #expect(outline.appLabel == "LINE Dev")
    }
}