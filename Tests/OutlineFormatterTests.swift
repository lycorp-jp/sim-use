// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

// MARK: - Helpers

private func decodeTree(_ json: String) throws -> [AccessibilityElement] {
    let data = Data(json.utf8)
    return try JSONDecoder().decode([AccessibilityElement].self, from: data)
}

private func render(_ json: String) throws -> Outline {
    OutlineFormatter.render(tree: try decodeTree(json))
}

// MARK: - Smoke

@Suite("OutlineFormatter Smoke")
struct OutlineFormatterSmokeTests {
    @Test("empty tree renders only a placeholder header")
    func emptyTree() {
        let outline = OutlineFormatter.render(tree: [])
        // The header is still useful even when the tree is empty; it
        // tells callers the tool ran and there was nothing to describe.
        #expect(outline.text == "Subtree: App\n")
        #expect(outline.entries.isEmpty)
    }

    @Test("app with no children emits only the header")
    func appHeaderOnly() throws {
        let outline = try render(#"""
        [
          {
            "type": "Application",
            "AXLabel": "Demo",
            "frame": { "x": 0, "y": 0, "width": 200, "height": 400 }
          }
        ]
        """#)
        #expect(outline.text == "App: Demo  200x400\n")
        #expect(outline.entries.isEmpty)
    }

    @Test("non-Application root is rendered as a subtree, including the root element")
    func nonApplicationRoot() throws {
        // Shape returned by `describe-ui --point`: a single element
        // object, not wrapped in an Application. The formatter should
        // list the element itself (not drop it as a wrapper) and use
        // the `Subtree:` header so the 0x0 dimension is not surfaced.
        let outline = try render(#"""
        [
          {
            "type": "Button", "AXLabel": "Hit",
            "frame": { "x": 10, "y": 20, "width": 30, "height": 30 }
          }
        ]
        """#)
        #expect(outline.text.hasPrefix("Subtree: Hit\n"))
        #expect(outline.entries.count == 1)
        #expect(outline.entries.first?.label == "Hit")
        #expect(outline.text.contains("[Content]"))
    }
}

// MARK: - Filtering

@Suite("OutlineFormatter Filtering")
struct OutlineFormatterFilteringTests {
    @Test("zero-size frames are dropped")
    func zeroSizeDropped() throws {
        let outline = try render(#"""
        [
          {
            "type": "Application", "AXLabel": "X",
            "frame": { "x": 0, "y": 0, "width": 200, "height": 400 },
            "children": [
              { "type": "Button", "AXLabel": "Real",
                "frame": { "x": 10, "y": 10, "width": 30, "height": 30 } },
              { "type": "Button", "AXLabel": "Phantom",
                "frame": { "x": 10, "y": 10, "width": 0, "height": 0 } }
            ]
          }
        ]
        """#)
        #expect(outline.entries.count == 1)
        #expect(outline.entries.first?.label == "Real")
    }

    @Test("elements outside the app frame are dropped")
    func outOfBoundsDropped() throws {
        let outline = try render(#"""
        [
          {
            "type": "Application", "AXLabel": "X",
            "frame": { "x": 0, "y": 0, "width": 200, "height": 400 },
            "children": [
              { "type": "Button", "AXLabel": "Inside",
                "frame": { "x": 10, "y": 10, "width": 30, "height": 30 } },
              { "type": "Button", "AXLabel": "Off-right",
                "frame": { "x": 250, "y": 10, "width": 30, "height": 30 } },
              { "type": "Button", "AXLabel": "Off-bottom",
                "frame": { "x": 10, "y": 500, "width": 30, "height": 30 } }
            ]
          }
        ]
        """#)
        #expect(outline.entries.count == 1)
        #expect(outline.entries.first?.label == "Inside")
    }

    @Test("group and its identical-frame child are deduplicated, deeper wins")
    func dedupWrapper() throws {
        let outline = try render(#"""
        [
          {
            "type": "Application", "AXLabel": "X",
            "frame": { "x": 0, "y": 0, "width": 200, "height": 400 },
            "children": [
              {
                "type": "Button", "AXLabel": "Buy",
                "frame": { "x": 10, "y": 100, "width": 40, "height": 40 },
                "children": [
                  { "type": "Button", "AXLabel": "Buy",
                    "frame": { "x": 10, "y": 100, "width": 40, "height": 40 } }
                ]
              }
            ]
          }
        ]
        """#)
        #expect(outline.entries.count == 1)
    }
}

// MARK: - Ordering

@Suite("OutlineFormatter Ordering")
struct OutlineFormatterOrderingTests {
    @Test("center-y tiebreaker puts visually-aligned elements in x order")
    func centerYTiebreaker() throws {
        // 菜单 and 新闻 mimic the LINE news header — different heights on
        // the same visual row, with tops at y=63 vs y=66 but centers at
        // 78 vs 78.
        let outline = try render(#"""
        [
          {
            "type": "Application", "AXLabel": "X",
            "frame": { "x": 0, "y": 0, "width": 402, "height": 400 },
            "children": [
              { "type": "Button", "AXLabel": "菜单",
                "frame": { "x": 359, "y": 63, "width": 30, "height": 30 } },
              { "type": "StaticText", "AXLabel": "新闻",
                "frame": { "x": 17, "y": 66, "width": 38, "height": 24 } }
            ]
          }
        ]
        """#)
        #expect(outline.entries.map(\.label) == ["新闻", "菜单"])
    }
}

// MARK: - Regions

@Suite("OutlineFormatter Regions")
struct OutlineFormatterRegionTests {
    @Test("declared AXGroup with label becomes a region and hides its wrapper")
    func declaredGroupRegion() throws {
        let outline = try render(#"""
        [
          {
            "type": "Application", "AXLabel": "X",
            "frame": { "x": 0, "y": 0, "width": 400, "height": 800 },
            "children": [
              {
                "type": "Group", "AXLabel": "TabBar label",
                "frame": { "x": 0, "y": 720, "width": 400, "height": 80 },
                "children": [
                  { "type": "RadioButton", "AXLabel": "A", "AXValue": 0,
                    "frame": { "x": 10, "y": 730, "width": 80, "height": 60 } },
                  { "type": "RadioButton", "AXLabel": "B", "AXValue": 1,
                    "frame": { "x": 100, "y": 730, "width": 80, "height": 60 } }
                ]
              }
            ]
          }
        ]
        """#)

        #expect(outline.entries.count == 2)
        #expect(outline.entries.map(\.label) == ["A", "B"])
        for entry in outline.entries {
            #expect(entry.region.kind == "Group")
            #expect(entry.region.label == "TabBar label")
        }
        #expect(outline.entries.last?.states == ["selected"])

        #expect(outline.text.contains("[Group  \"TabBar label\"]"))
        #expect(!outline.text.contains("@3"))
    }

    @Test("y-band fallback partitions into Top / Content / Bottom")
    func yBandPartition() throws {
        let outline = try render(#"""
        [
          {
            "type": "Application", "AXLabel": "X",
            "frame": { "x": 0, "y": 0, "width": 400, "height": 800 },
            "children": [
              { "type": "StaticText", "AXLabel": "statusbar",
                "frame": { "x": 0, "y": 20, "width": 40, "height": 20 } },
              { "type": "Button", "AXLabel": "middle",
                "frame": { "x": 100, "y": 400, "width": 80, "height": 40 } },
              { "type": "Button", "AXLabel": "home-indicator",
                "frame": { "x": 100, "y": 770, "width": 80, "height": 10 } }
            ]
          }
        ]
        """#)
        let kinds = outline.entries.map(\.region.kind)
        #expect(kinds == ["Top", "Content", "Bottom"])
        for entry in outline.entries {
            #expect(entry.region.label == nil)
        }
    }
}

// MARK: - State tags

@Suite("OutlineFormatter State Tags")
struct OutlineFormatterStateTests {
    @Test("RadioButton with AXValue=1 is selected")
    func selectedRadio() throws {
        let outline = try render(#"""
        [
          {
            "type": "Application", "AXLabel": "X",
            "frame": { "x": 0, "y": 0, "width": 200, "height": 400 },
            "children": [
              { "type": "RadioButton", "AXLabel": "Tab",
                "AXValue": 1,
                "frame": { "x": 10, "y": 100, "width": 40, "height": 40 } }
            ]
          }
        ]
        """#)
        #expect(outline.entries.first?.states == ["selected"])
    }

    @Test("disabled flag surfaces a disabled tag")
    func disabledFlag() throws {
        let outline = try render(#"""
        [
          {
            "type": "Application", "AXLabel": "X",
            "frame": { "x": 0, "y": 0, "width": 200, "height": 400 },
            "children": [
              { "type": "Button", "AXLabel": "Go",
                "enabled": false,
                "frame": { "x": 10, "y": 100, "width": 40, "height": 40 } }
            ]
          }
        ]
        """#)
        #expect(outline.entries.first?.states == ["disabled"])
    }

    @Test("TextField AXValue surfaces a quoted value tag")
    func textFieldValue() throws {
        let outline = try render(#"""
        [
          {
            "type": "Application", "AXLabel": "X",
            "frame": { "x": 0, "y": 0, "width": 200, "height": 400 },
            "children": [
              { "type": "TextField", "AXLabel": "Email",
                "AXValue": "hello@example.com",
                "frame": { "x": 10, "y": 100, "width": 180, "height": 40 } }
            ]
          }
        ]
        """#)
        #expect(outline.entries.first?.states == [#"value="hello@example.com""#])
    }
}

// MARK: - Label escaping

@Suite("OutlineFormatter Label Escaping")
struct OutlineFormatterLabelTests {
    @Test("long labels are grapheme-truncated with an ellipsis")
    func truncation() {
        let result = OutlineFormatter.escapeAndTruncate(String(repeating: "a", count: 100), maxGraphemes: 10)
        #expect(result.count == 10)
        #expect(result.hasSuffix("…"))
    }

    @Test("internal newlines and tabs collapse to single space")
    func whitespaceCollapse() {
        let result = OutlineFormatter.escapeAndTruncate("a\n\nb\tc\r\nd", maxGraphemes: 60)
        #expect(result == "a b c d")
    }

    @Test("double quotes and backslashes are escaped")
    func quotesEscaped() {
        let result = OutlineFormatter.escapeAndTruncate(#"a"b\c"#, maxGraphemes: 60)
        #expect(result == #"a\"b\\c"#)
    }
}

// MARK: - Full golden render

@Suite("OutlineFormatter Golden")
struct OutlineFormatterGoldenTests {
    @Test("realistic LINE news page shape renders as expected")
    func lineNewsShape() throws {
        let json = #"""
        [
          {
            "type": "Application", "AXLabel": "LINE Dev",
            "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
            "children": [
              { "type": "StaticText", "AXLabel": "10:35",
                "frame": { "x": 51, "y": 22, "width": 45, "height": 20 } },
              { "type": "StaticText", "AXLabel": "新闻",
                "frame": { "x": 17, "y": 66, "width": 38, "height": 24 } },
              { "type": "Button", "AXLabel": "菜单",
                "frame": { "x": 359, "y": 63, "width": 30, "height": 30 } },
              {
                "type": "Group", "AXLabel": "标签页栏",
                "frame": { "x": 0, "y": 791, "width": 402, "height": 83 },
                "children": [
                  { "type": "RadioButton", "AXLabel": "主页", "AXValue": 0,
                    "frame": { "x": 2, "y": 792, "width": 76, "height": 48 } },
                  { "type": "RadioButton", "AXLabel": "聊天", "AXValue": 0,
                    "frame": { "x": 82, "y": 792, "width": 77, "height": 48 } },
                  { "type": "RadioButton", "AXLabel": "新闻", "AXValue": 1,
                    "frame": { "x": 243, "y": 792, "width": 77, "height": 48 } }
                ]
              }
            ]
          }
        ]
        """#
        let outline = try render(json)
        let expected = """
        App: LINE Dev  402x874

        [Top  y<120]
          @1  StaticText  "10:35"  (51,22 45x20)
          @2  StaticText  "新闻"  (17,66 38x24)
          @3  Button  "菜单"  (359,63 30x30)

        [Group  "标签页栏"]
          @4  RadioButton  "主页"  (2,792 76x48)
          @5  RadioButton  "聊天"  (82,792 77x48)
          @6  RadioButton  "新闻"  (243,792 77x48)  selected

        """
        #expect(outline.text == expected)
    }

    @Test("dominant list cells gain bare #N aliases and outline.lists is populated")
    func dominantListAliases() throws {
        let outline = try render(#"""
        [{
          "type": "Application", "AXLabel": "Chats",
          "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
          "children": [{
            "type": "Group", "AXLabel": "ChatList",
            "frame": { "x": 0, "y": 100, "width": 402, "height": 408 },
            "children": [
              { "type": "Button", "AXLabel": "Alice", "frame": { "x": 0, "y": 100, "width": 402, "height": 68 } },
              { "type": "Button", "AXLabel": "Bob",   "frame": { "x": 0, "y": 168, "width": 402, "height": 68 } },
              { "type": "Button", "AXLabel": "Carol", "frame": { "x": 0, "y": 236, "width": 402, "height": 68 } }
            ]
          }]
        }]
        """#)

        // Three rows → three list cells, scope=1 (dominant), bare #N.
        #expect(outline.entries.count == 3)
        for (idx, entry) in outline.entries.enumerated() {
            let alias = try #require(entry.aliases.list)
            #expect(alias.scope == 1)
            #expect(alias.index == idx + 1)
        }

        // Text rendering: bare `#N` for dominant list, no `@1` suffix.
        #expect(outline.text.contains("@1 #1"))
        #expect(outline.text.contains("@2 #2"))
        #expect(outline.text.contains("@3 #3"))
        #expect(!outline.text.contains("#1@1"))  // dominant never renders @M

        // Outline.lists populated with one summary.
        #expect(outline.lists.count == 1)
        let summary = try #require(outline.lists.first)
        #expect(summary.scope == 1)
        #expect(summary.cellCount == 3)
        #expect(summary.cellHeight == 68)
        #expect(summary.containerLabel == "ChatList")
    }

    @Test("multi-list rendering: dominant uses bare #N, secondary uses #N@M")
    func multiListRendering() throws {
        let outline = try render(#"""
        [{
          "type": "Application", "AXLabel": "Share",
          "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
          "children": [
            {
              "type": "Group", "AXLabel": "Friends",
              "frame": { "x": 0, "y": 140, "width": 402, "height": 600 },
              "children": [
                { "type": "Cell", "AXLabel": "Alice", "frame": { "x": 0, "y": 140, "width": 402, "height": 59 } },
                { "type": "Cell", "AXLabel": "Bob",   "frame": { "x": 0, "y": 199, "width": 402, "height": 59 } },
                { "type": "Cell", "AXLabel": "Carol", "frame": { "x": 0, "y": 258, "width": 402, "height": 59 } },
                { "type": "Cell", "AXLabel": "Dan",   "frame": { "x": 0, "y": 317, "width": 402, "height": 59 } }
              ]
            },
            {
              "type": "Group", "AXLabel": "Groups",
              "frame": { "x": 0, "y": 460, "width": 402, "height": 200 },
              "children": [
                { "type": "Cell", "AXLabel": "Project Phoenix", "frame": { "x": 0, "y": 460, "width": 402, "height": 50 } },
                { "type": "Cell", "AXLabel": "Lunch Club",      "frame": { "x": 0, "y": 510, "width": 402, "height": 50 } }
              ]
            }
          ]
        }]
        """#)

        #expect(outline.lists.count == 2)
        #expect(outline.lists[0].containerLabel == "Friends")
        #expect(outline.lists[1].containerLabel == "Groups")

        // Friends cells: dominant (#N).
        let alice = try #require(outline.entries.first { $0.label == "Alice" })
        #expect(alice.aliases.list?.scope == 1)
        #expect(alice.aliases.list?.index == 1)

        // Groups cells: scoped (#N@2).
        let phoenix = try #require(outline.entries.first { $0.label == "Project Phoenix" })
        #expect(phoenix.aliases.list?.scope == 2)
        #expect(phoenix.aliases.list?.index == 1)

        // Text: scope=1 prints bare; scope=2 prints @2 suffix.
        #expect(outline.text.contains("@\(alice.aliases.at) #1 "))
        #expect(outline.text.contains("@\(phoenix.aliases.at) #1@2"))
    }

    @Test("multi-list golden: byte-stable outline text")
    func multiListGolden() throws {
        let outline = try render(#"""
        [{
          "type": "Application", "AXLabel": "Share",
          "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
          "children": [
            {
              "type": "Group", "AXLabel": "Friends",
              "frame": { "x": 0, "y": 140, "width": 402, "height": 240 },
              "children": [
                { "type": "Cell", "AXLabel": "Alice", "frame": { "x": 0, "y": 140, "width": 402, "height": 60 } },
                { "type": "Cell", "AXLabel": "Bob",   "frame": { "x": 0, "y": 200, "width": 402, "height": 60 } },
                { "type": "Cell", "AXLabel": "Carol", "frame": { "x": 0, "y": 260, "width": 402, "height": 60 } }
              ]
            },
            {
              "type": "Group", "AXLabel": "Groups",
              "frame": { "x": 0, "y": 460, "width": 402, "height": 100 },
              "children": [
                { "type": "Cell", "AXLabel": "Project Phoenix", "frame": { "x": 0, "y": 460, "width": 402, "height": 50 } },
                { "type": "Cell", "AXLabel": "Lunch Club",      "frame": { "x": 0, "y": 510, "width": 402, "height": 50 } }
              ]
            }
          ]
        }]
        """#)
        let expected = """
        App: Share  402x874

        [Group  "Friends"]
          @1 #1  Cell  "Alice"  (0,140 402x60)
          @2 #2  Cell  "Bob"  (0,200 402x60)
          @3 #3  Cell  "Carol"  (0,260 402x60)

        [Group  "Groups"]
          @4 #1@2  Cell  "Project Phoenix"  (0,460 402x50)
          @5 #2@2  Cell  "Lunch Club"  (0,510 402x50)

        """
        #expect(outline.text == expected)
    }

    @Test("AXUniqueId surfaces inline as #<id> after the label")
    func uniqueIdSuffix() throws {
        let outline = try render(#"""
        [
          {
            "type": "Application", "AXLabel": "App",
            "frame": { "x": 0, "y": 0, "width": 400, "height": 800 },
            "children": [
              { "type": "Button", "AXLabel": "Settings", "AXUniqueId": "settingsButton",
                "frame": { "x": 10, "y": 20, "width": 40, "height": 40 } },
              { "type": "Button", "AXLabel": "No-id",
                "frame": { "x": 60, "y": 20, "width": 40, "height": 40 } }
            ]
          }
        ]
        """#)

        let first = outline.entries[0]
        #expect(first.uniqueId == "settingsButton")
        let second = outline.entries[1]
        #expect(second.uniqueId == nil)

        // Text rendering: #id between label and frame; omitted otherwise.
        #expect(outline.text.contains("@1  Button  \"Settings\"  #settingsButton  (10,20 40x40)"))
        #expect(outline.text.contains("@2  Button  \"No-id\"  (60,20 40x40)"))
    }
}