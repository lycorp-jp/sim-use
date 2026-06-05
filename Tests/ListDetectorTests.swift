// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import Foundation
import Testing

private func decodeTree(_ json: String) throws -> [AccessibilityElement] {
    let data = Data(json.utf8)
    return try JSONDecoder().decode([AccessibilityElement].self, from: data)
}

@Suite("ListDetector — single list")
struct ListDetectorSingleListTests {
    @Test("detects 6 same-height button rows under a Group")
    func dominantChats() throws {
        // Mirrors the LINE Dev Chats tab: 6 Button rows at 402x68 with
        // perfectly uniform Δy. Spike fixture shows score ≈ 11.7 on this
        // shape (6 × 1.0 × 1.5 × 1.3).
        let tree = try decodeTree(#"""
        [{
          "type": "Application", "AXLabel": "LINE",
          "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
          "children": [{
            "type": "Group", "AXLabel": "ChatList",
            "frame": { "x": 0, "y": 100, "width": 402, "height": 408 },
            "children": [
              { "type": "Button", "AXLabel": "Alice", "frame": { "x": 0, "y": 100, "width": 402, "height": 68 } },
              { "type": "Button", "AXLabel": "Bob",   "frame": { "x": 0, "y": 168, "width": 402, "height": 68 } },
              { "type": "Button", "AXLabel": "Carol", "frame": { "x": 0, "y": 236, "width": 402, "height": 68 } },
              { "type": "Button", "AXLabel": "Dave",  "frame": { "x": 0, "y": 304, "width": 402, "height": 68 } },
              { "type": "Button", "AXLabel": "Eve",   "frame": { "x": 0, "y": 372, "width": 402, "height": 68 } },
              { "type": "Button", "AXLabel": "Frank", "frame": { "x": 0, "y": 440, "width": 402, "height": 68 } }
            ]
          }]
        }]
        """#)
        let clusters = ListDetector.detect(tree: tree)
        #expect(clusters.count == 1)
        let dom = try #require(clusters.first)
        #expect(dom.cells.count == 6)
        #expect(dom.cellHeight == 68)
        #expect(dom.containerRole == "Group")
        #expect(dom.containerLabel == "ChatList")
        #expect(dom.score > 5.0)  // 6 × 1.0 × 1.5 × 1.3 = 11.7
        // Cells are emitted in (y, x) order; first row should be Alice's frame.
        #expect(dom.cells.first?.frame.y == 100)
        #expect(dom.cells.last?.frame.y == 440)
    }

    @Test("returns empty for a screen with no list")
    func splashNoList() throws {
        let tree = try decodeTree(#"""
        [{
          "type": "Application", "AXLabel": "Splash",
          "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
          "children": [
            { "type": "Image", "AXLabel": "Logo", "frame": { "x": 100, "y": 200, "width": 200, "height": 200 } },
            { "type": "Button", "AXLabel": "Start", "frame": { "x": 100, "y": 600, "width": 200, "height": 50 } }
          ]
        }]
        """#)
        // Two children, but heights are different (200 vs 50) → no cluster.
        let clusters = ListDetector.detect(tree: tree)
        #expect(clusters.isEmpty)
    }

    @Test("horizontal row (Δy=0) scores 0 and drops out")
    func horizontalTabBar() throws {
        // 5 same-height tabs at the same y — a tab bar, not a list.
        let tree = try decodeTree(#"""
        [{
          "type": "Application", "AXLabel": "Demo",
          "frame": { "x": 0, "y": 0, "width": 400, "height": 800 },
          "children": [{
            "type": "Group", "AXLabel": "TabBar",
            "frame": { "x": 0, "y": 750, "width": 400, "height": 50 },
            "children": [
              { "type": "Tab", "AXLabel": "T1", "frame": { "x":   0, "y": 750, "width": 80, "height": 50 } },
              { "type": "Tab", "AXLabel": "T2", "frame": { "x":  80, "y": 750, "width": 80, "height": 50 } },
              { "type": "Tab", "AXLabel": "T3", "frame": { "x": 160, "y": 750, "width": 80, "height": 50 } },
              { "type": "Tab", "AXLabel": "T4", "frame": { "x": 240, "y": 750, "width": 80, "height": 50 } },
              { "type": "Tab", "AXLabel": "T5", "frame": { "x": 320, "y": 750, "width": 80, "height": 50 } }
            ]
          }]
        }]
        """#)
        let clusters = ListDetector.detect(tree: tree)
        #expect(clusters.isEmpty)
    }

    @Test("Button + StaticText pair at identical frame collapses to Button")
    func frameDedupePicksActionable() throws {
        // iOS commonly exposes a row both as a Button (tap target) and
        // as a StaticText (composite VoiceOver label) at the same frame.
        // Detector must collapse them and report the Button.
        let tree = try decodeTree(#"""
        [{
          "type": "Application", "AXLabel": "Demo",
          "frame": { "x": 0, "y": 0, "width": 400, "height": 800 },
          "children": [{
            "type": "Group", "AXLabel": "Rows",
            "frame": { "x": 0, "y": 100, "width": 400, "height": 200 },
            "children": [
              { "type": "Button",     "AXLabel": "Row 1",                 "frame": { "x": 0, "y": 100, "width": 400, "height": 60 } },
              { "type": "StaticText", "AXLabel": "Row 1, last message",   "frame": { "x": 0, "y": 100, "width": 400, "height": 60 } },
              { "type": "Button",     "AXLabel": "Row 2",                 "frame": { "x": 0, "y": 160, "width": 400, "height": 60 } },
              { "type": "StaticText", "AXLabel": "Row 2, last message",   "frame": { "x": 0, "y": 160, "width": 400, "height": 60 } },
              { "type": "Button",     "AXLabel": "Row 3",                 "frame": { "x": 0, "y": 220, "width": 400, "height": 60 } },
              { "type": "StaticText", "AXLabel": "Row 3, last message",   "frame": { "x": 0, "y": 220, "width": 400, "height": 60 } }
            ]
          }]
        }]
        """#)
        let clusters = ListDetector.detect(tree: tree)
        let dom = try #require(clusters.first)
        #expect(dom.cells.count == 3)
        #expect(dom.cells.allSatisfy { $0.role == "Button" })
    }

    @Test("tolerates a single Δy outlier (ad insert)")
    func adInsertTolerance() throws {
        // News-feed shape: 4 article rows + 1 large gap from an ad tile
        // sandwiched between rows. 3 of 4 gaps are uniform — consistency
        // = 0.75 still keeps the score positive and emits the cluster.
        let tree = try decodeTree(#"""
        [{
          "type": "Application", "AXLabel": "News",
          "frame": { "x": 0, "y": 0, "width": 400, "height": 800 },
          "children": [{
            "type": "Group", "AXLabel": "Feed",
            "frame": { "x": 0, "y": 100, "width": 400, "height": 600 },
            "children": [
              { "type": "Link", "AXLabel": "Article A", "frame": { "x": 80, "y": 100, "width": 240, "height": 41 } },
              { "type": "Link", "AXLabel": "Article B", "frame": { "x": 80, "y": 160, "width": 240, "height": 41 } },
              { "type": "Link", "AXLabel": "Article C", "frame": { "x": 80, "y": 220, "width": 240, "height": 41 } },
              { "type": "Image","AXLabel": "Ad",        "frame": { "x":  0, "y": 280, "width": 400, "height": 220 } },
              { "type": "Link", "AXLabel": "Article D", "frame": { "x": 80, "y": 510, "width": 240, "height": 41 } },
              { "type": "Link", "AXLabel": "Article E", "frame": { "x": 80, "y": 570, "width": 240, "height": 41 } }
            ]
          }]
        }]
        """#)
        let clusters = ListDetector.detect(tree: tree)
        let dom = try #require(clusters.first)
        #expect(dom.cellHeight == 41)
        #expect(dom.cells.count == 5)
    }
}

@Suite("ListDetector — multiple lists")
struct ListDetectorMultiListTests {
    @Test("emits two disjoint lists in dominance order")
    func sharePicker() throws {
        // Two Groups, each with same-height cells but different heights
        // and member counts. Dominant should be the larger / better-
        // scoring group.
        let tree = try decodeTree(#"""
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
                { "type": "Cell", "AXLabel": "Dan",   "frame": { "x": 0, "y": 317, "width": 402, "height": 59 } },
                { "type": "Cell", "AXLabel": "Eve",   "frame": { "x": 0, "y": 376, "width": 402, "height": 59 } }
              ]
            },
            {
              "type": "Group", "AXLabel": "Groups",
              "frame": { "x": 0, "y": 460, "width": 402, "height": 200 },
              "children": [
                { "type": "Cell", "AXLabel": "Project Phoenix", "frame": { "x": 0, "y": 460, "width": 402, "height": 50 } },
                { "type": "Cell", "AXLabel": "Lunch Club",      "frame": { "x": 0, "y": 510, "width": 402, "height": 50 } },
                { "type": "Cell", "AXLabel": "Book Club",       "frame": { "x": 0, "y": 560, "width": 402, "height": 50 } }
              ]
            }
          ]
        }]
        """#)
        let clusters = ListDetector.detect(tree: tree)
        #expect(clusters.count == 2)
        // Friends (5 cells, h=59) beats Groups (3 cells, h=50) on size.
        #expect(clusters[0].cells.count == 5)
        #expect(clusters[0].cellHeight == 59)
        #expect(clusters[0].containerLabel == "Friends")
        #expect(clusters[1].cells.count == 3)
        #expect(clusters[1].cellHeight == 50)
        #expect(clusters[1].containerLabel == "Groups")
        // Score must be strictly decreasing.
        #expect(clusters[0].score > clusters[1].score)
    }

    @Test("overlapping clusters: dominant wins, secondary is dropped")
    func disjointGuarantee() throws {
        // Same set of cells exposed under both a parent Group and a
        // grand-parent Application: detection finds the cluster twice
        // (once per container), but greedy emission keeps only the
        // first. No element is double-counted.
        let tree = try decodeTree(#"""
        [{
          "type": "Application", "AXLabel": "Demo",
          "frame": { "x": 0, "y": 0, "width": 400, "height": 800 },
          "children": [{
            "type": "Group", "AXLabel": "Outer",
            "frame": { "x": 0, "y": 100, "width": 400, "height": 600 },
            "children": [
              { "type": "Cell", "AXLabel": "A", "frame": { "x": 0, "y": 100, "width": 400, "height": 60 } },
              { "type": "Cell", "AXLabel": "B", "frame": { "x": 0, "y": 160, "width": 400, "height": 60 } },
              { "type": "Cell", "AXLabel": "C", "frame": { "x": 0, "y": 220, "width": 400, "height": 60 } }
            ]
          }]
        }]
        """#)
        let clusters = ListDetector.detect(tree: tree)
        #expect(clusters.count == 1)
        #expect(clusters[0].cells.count == 3)
    }
}

// MARK: - Gate-specific tests

@Suite("ListDetector — gates")
struct ListDetectorGateTests {
    @Test("widthRatio gate drops a 2-cell cluster with disparate widths")
    func widthRatioDropsBannerLabelPair() throws {
        // Two StaticText at same h=16 inside a banner: a long title and
        // a short "later" CTA. Same height, but widths 49 vs 183 spans
        // ratio 3.73 — not a list.
        let tree = try decodeTree(#"""
        [{
          "type": "Application", "AXLabel": "X",
          "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
          "children": [{
            "type": "Group", "AXLabel": "Banner",
            "frame": { "x": 0, "y": 600, "width": 402, "height": 200 },
            "children": [
              { "type": "StaticText", "AXLabel": "Long banner title text", "frame": { "x": 132, "y": 684, "width": 183, "height": 16 } },
              { "type": "StaticText", "AXLabel": "Skip", "frame": { "x": 225, "y": 707, "width": 49, "height": 16 } }
            ]
          }]
        }]
        """#)
        #expect(ListDetector.detect(tree: tree, screenHeight: 874).isEmpty)
    }

    @Test("minMeanWidth gate drops a tiny-icon pair")
    func minMeanWidthDropsBannerIcons() throws {
        // Two same-h tiny banner buttons (17×17) stacked vertically.
        // Wide-enough match in widthRatio (1.0), but mean 17pt is far
        // below the 80pt floor — drop.
        let tree = try decodeTree(#"""
        [{
          "type": "Application", "AXLabel": "X",
          "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
          "children": [{
            "type": "Group", "AXLabel": "Banner",
            "frame": { "x": 0, "y": 100, "width": 402, "height": 200 },
            "children": [
              { "type": "Button", "AXLabel": "mute", "frame": { "x": 372, "y": 160, "width": 17, "height": 17 } },
              { "type": "Button", "AXLabel": "more", "frame": { "x": 372, "y": 232, "width": 17, "height": 17 } }
            ]
          }]
        }]
        """#)
        #expect(ListDetector.detect(tree: tree, screenHeight: 874).isEmpty)
    }

    @Test("density gate drops cells scattered far apart vertically")
    func densityDropsScatteredCTAs() throws {
        // Two h=16 cells at y=580 and y=817 — gap 237 ≫ 3.5 × 16 = 56.
        // Heights and widths are list-shaped on paper but they're not
        // adjacent in any real sense.
        let tree = try decodeTree(#"""
        [{
          "type": "Application", "AXLabel": "X",
          "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
          "children": [{
            "type": "Group", "AXLabel": "Page",
            "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
            "children": [
              { "type": "Button", "AXLabel": "View calendar", "frame": { "x": 289, "y": 580, "width": 97, "height": 16 } },
              { "type": "StaticText", "AXLabel": "View all albums", "frame": { "x": 137, "y": 817, "width": 134, "height": 16 } }
            ]
          }]
        }]
        """#)
        #expect(ListDetector.detect(tree: tree, screenHeight: 874).isEmpty)
    }

    @Test("consistency gate drops a 3-cell cluster with one large outlier gap")
    func consistencyDropsScatteredButtons() throws {
        // 3 same-shape Buttons but unevenly spaced: gaps [411, 77].
        // Median 411, only 1 of 2 gaps within tolerance → 0.5 < 2/3.
        let tree = try decodeTree(#"""
        [{
          "type": "Application", "AXLabel": "X",
          "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
          "children": [{
            "type": "Group", "AXLabel": "Page",
            "frame": { "x": 0, "y": 100, "width": 402, "height": 700 },
            "children": [
              { "type": "Button", "AXLabel": "Action1", "frame": { "x": 0, "y": 267, "width": 402, "height": 48 } },
              { "type": "Button", "AXLabel": "Action2", "frame": { "x": 0, "y": 678, "width": 402, "height": 48 } },
              { "type": "Button", "AXLabel": "Action3", "frame": { "x": 0, "y": 755, "width": 402, "height": 48 } }
            ]
          }]
        }]
        """#)
        #expect(ListDetector.detect(tree: tree, screenHeight: 874).isEmpty)
    }

    @Test("absolute-gap gate drops a 2-cell cluster with screen-spanning gap")
    func absoluteGapDropsCrossScreenPair() throws {
        // 2 cells at y=100 and y=600, gap 460. Density 460/30=15.3 also
        // fails, but this test exercises the absolute screen-relative
        // gate path: 460 / 874 ≈ 53% > 25%.
        let tree = try decodeTree(#"""
        [{
          "type": "Application", "AXLabel": "X",
          "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
          "children": [{
            "type": "Group", "AXLabel": "Page",
            "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
            "children": [
              { "type": "Button", "AXLabel": "Top",    "frame": { "x": 0, "y": 100, "width": 402, "height": 30 } },
              { "type": "Button", "AXLabel": "Bottom", "frame": { "x": 0, "y": 600, "width": 402, "height": 30 } }
            ]
          }]
        }]
        """#)
        #expect(ListDetector.detect(tree: tree, screenHeight: 874).isEmpty)
    }

    @Test("nestedness gate drops sub-text rows visually inside dominant rows")
    func nestednessDropsRowDescriptions() throws {
        // 2 settings rows, each with an inset GenericElement description.
        // The descriptions form their own row-shaped cluster (x=16,
        // w=370, same height) but every cell is geometrically inside a
        // dominant row. Nestedness gate drops the descriptions.
        let tree = try decodeTree(#"""
        [{
          "type": "Application", "AXLabel": "X",
          "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
          "children": [{
            "type": "Group", "AXLabel": "Settings",
            "frame": { "x": 0, "y": 100, "width": 402, "height": 600 },
            "children": [
              { "type": "GenericElement", "AXLabel": "Toggle A, On", "frame": { "x": 0, "y": 100, "width": 402, "height": 87 } },
              { "type": "GenericElement", "AXLabel": "Description A line", "frame": { "x": 16, "y": 145, "width": 370, "height": 30 } },
              { "type": "GenericElement", "AXLabel": "Toggle B, Off", "frame": { "x": 0, "y": 200, "width": 402, "height": 87 } },
              { "type": "GenericElement", "AXLabel": "Description B line", "frame": { "x": 16, "y": 245, "width": 370, "height": 30 } }
            ]
          }]
        }]
        """#)
        let clusters = ListDetector.detect(tree: tree, screenHeight: 874)
        #expect(clusters.count == 1)
        let dom = try #require(clusters.first)
        // Only the 2 outer rows should be picked; descriptions filtered.
        #expect(dom.cells.count == 2)
        #expect(dom.cells.allSatisfy { $0.frame.x == 0 && $0.frame.width == 402 })
    }

    @Test("maxCellHeight gate drops giant Group containers at the Application level")
    func maxCellHeightDropsContainers() throws {
        // Two Group children of the Application: each h ≈ 35% of screen.
        // They look "row-shaped" by x=0 width=402 but they're way too
        // tall to be list cells.
        let tree = try decodeTree(#"""
        [{
          "type": "Application", "AXLabel": "X",
          "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
          "children": [
            { "type": "Group", "AXLabel": "TopHalf",
              "frame": { "x": 0, "y": 0, "width": 402, "height": 320 } },
            { "type": "Group", "AXLabel": "BottomHalf",
              "frame": { "x": 0, "y": 320, "width": 402, "height": 320 } }
          ]
        }]
        """#)
        #expect(ListDetector.detect(tree: tree, screenHeight: 874).isEmpty)
    }
}

// MARK: - Variable-height (row-shaped pass)

@Suite("ListDetector — row-shaped pass")
struct ListDetectorRowShapedTests {
    @Test("variable-height settings list is detected as one cluster")
    func variableHeightSettingsList() throws {
        // iOS settings menu shape: 7 rows at the same x with mixed
        // heights (87/48/87/87/102/48/48) and a Heading at x=16. The
        // height-pass would split this into multiple low-consistency
        // sub-clusters; the row-shaped pass groups them all.
        let tree = try decodeTree(#"""
        [{
          "type": "Application", "AXLabel": "Settings",
          "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
          "children": [{
            "type": "Group", "AXLabel": "Account",
            "frame": { "x": 0, "y": 100, "width": 402, "height": 720 },
            "children": [
              { "type": "Button", "AXLabel": "連動アプリ", "frame": { "x": 0, "y": 112, "width": 402, "height": 87 } },
              { "type": "Heading", "AXLabel": "ログイン・セキュリティ", "frame": { "x": 16, "y": 242, "width": 370, "height": 15 } },
              { "type": "Button", "AXLabel": "他の端末と連携", "frame": { "x": 0, "y": 267, "width": 402, "height": 48 } },
              { "type": "GenericElement", "AXLabel": "ログイン許可, オン", "frame": { "x": 0, "y": 315, "width": 402, "height": 87 } },
              { "type": "GenericElement", "AXLabel": "Webログインの2要素認証, オフ", "frame": { "x": 0, "y": 431, "width": 402, "height": 87 } },
              { "type": "GenericElement", "AXLabel": "パスワードでログイン, オン", "frame": { "x": 0, "y": 547, "width": 402, "height": 102 } },
              { "type": "Button", "AXLabel": "ログイン中の端末", "frame": { "x": 0, "y": 678, "width": 402, "height": 48 } },
              { "type": "Button", "AXLabel": "アカウント削除", "frame": { "x": 0, "y": 755, "width": 402, "height": 48 } }
            ]
          }]
        }]
        """#)
        let clusters = ListDetector.detect(tree: tree, screenHeight: 874)
        #expect(clusters.count == 1)
        let dom = try #require(clusters.first)
        #expect(dom.cells.count == 7)
        // Heading at x=16 is excluded (different x bucket + Heading role
        // exclusion); the 7 actual rows are picked.
        #expect(dom.cells.allSatisfy { $0.frame.x == 0 && $0.frame.width == 402 })
        // Cells span heights 48–102; cellHeight is the median.
        let heights = dom.cells.map(\.frame.height).sorted()
        #expect(heights.first == 48)
        #expect(heights.last == 102)
    }

    @Test("section header at different x is excluded from row cluster")
    func sectionHeaderExcluded() throws {
        // Heading at x=16 width=370 is technically the same x as the
        // descriptions on the settings page and would otherwise bucket
        // separately. Even when a header sits at the same x as rows,
        // the Heading role exclusion keeps it out of the cluster.
        let tree = try decodeTree(#"""
        [{
          "type": "Application", "AXLabel": "X",
          "frame": { "x": 0, "y": 0, "width": 402, "height": 874 },
          "children": [{
            "type": "Group", "AXLabel": "Page",
            "frame": { "x": 0, "y": 100, "width": 402, "height": 600 },
            "children": [
              { "type": "Heading", "AXLabel": "Section",   "frame": { "x": 0, "y": 100, "width": 402, "height": 30 } },
              { "type": "Button",  "AXLabel": "Item 1",    "frame": { "x": 0, "y": 130, "width": 402, "height": 60 } },
              { "type": "Button",  "AXLabel": "Item 2",    "frame": { "x": 0, "y": 190, "width": 402, "height": 60 } },
              { "type": "Button",  "AXLabel": "Item 3",    "frame": { "x": 0, "y": 250, "width": 402, "height": 60 } }
            ]
          }]
        }]
        """#)
        let dom = try #require(ListDetector.detect(tree: tree, screenHeight: 874).first)
        #expect(dom.cells.count == 3)
        #expect(dom.cells.allSatisfy { $0.role == "Button" })
    }
}

// MARK: - Real-screen fixtures (regression coverage)

@Suite("ListDetector — fixtures from real screens")
struct ListDetectorFixtureTests {
    private func loadFixture(_ name: String) throws -> [AccessibilityElement] {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/list-detection/\(name)", withExtension: "json"),
            "Fixture '\(name).json' not bundled. Add the file under Tests/Fixtures/list-detection/ and re-run."
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([AccessibilityElement].self, from: data)
    }

    @Test("LINE Dev account-settings: 7-cell variable-height list, no false positives")
    func accountSettingsRealTree() throws {
        // Captured from a live LINE Dev simulator on the Account
        // settings sheet. Pre-fix, the detector emitted 4 clusters
        // (1 valid 2-cell + 3 false positives). After v1 gates +
        // row-shaped pass + nestedness gate it should emit exactly
        // one cluster covering the 7 visible rows.
        let tree = try loadFixture("account-settings.raw")
        let clusters = ListDetector.detect(tree: tree, screenHeight: 874)
        #expect(clusters.count == 1)

        let dom = try #require(clusters.first)
        #expect(dom.cells.count == 7)

        // Every cell sits at x=0 and width 402 — full-row, the row-
        // shaped pass signature.
        #expect(dom.cells.allSatisfy { $0.frame.x == 0 && $0.frame.width == 402 })

        // Cells span heights 48..102. Verifies variable-height
        // tolerance.
        let heights = Set(dom.cells.map(\.frame.height))
        #expect(heights.contains(48))
        #expect(heights.contains(87))
        #expect(heights.contains(102))

        // The (16, w=370) inset description GenericElements that used
        // to leak as `#1@2`-`#3@2` must not surface in any picked
        // cluster.
        let hasDescriptionFrame = clusters.contains { cluster in
            cluster.cells.contains { $0.frame.x == 16 && $0.frame.width == 370 }
        }
        #expect(!hasDescriptionFrame)
    }

    @Test("LINE Dev friends-tab patterns: 1 real list, 0 false positives")
    func friendsTabSynthetic() throws {
        // Synthetic but structurally identical to the friends-tab
        // patterns observed pre-fix: a banner with two narrow labels
        // (widthRatio=3.73), two tiny icons (mean width 17pt), three
        // real friend rows (h=68 stacked), and two scattered CTAs at
        // y=580/817 sharing h=16.
        //
        // Pre-fix, the detector emitted 4 clusters. After v1 gates the
        // banner labels drop on widthRatio, the icons drop on
        // minMeanWidth, the CTAs drop on density, and only the real
        // friend rows remain.
        let tree = try loadFixture("friends-tab-synthetic")
        let clusters = ListDetector.detect(tree: tree, screenHeight: 874)
        #expect(clusters.count == 1)

        let dom = try #require(clusters.first)
        #expect(dom.cells.count == 3)
        #expect(dom.cellHeight == 68)
        #expect(dom.containerLabel == "FriendsList")
    }
}

@Suite("ListDetector — bbox")
struct ListDetectorBBoxTests {
    @Test("bbox unions the member cell frames")
    func bboxComputed() throws {
        let tree = try decodeTree(#"""
        [{
          "type": "Application", "AXLabel": "X",
          "frame": { "x": 0, "y": 0, "width": 400, "height": 800 },
          "children": [{
            "type": "Group", "AXLabel": "L",
            "frame": { "x": 0, "y": 100, "width": 400, "height": 200 },
            "children": [
              { "type": "Cell", "AXLabel": "1", "frame": { "x": 16, "y": 100, "width": 200, "height": 50 } },
              { "type": "Cell", "AXLabel": "2", "frame": { "x": 16, "y": 150, "width": 280, "height": 50 } },
              { "type": "Cell", "AXLabel": "3", "frame": { "x": 16, "y": 200, "width": 240, "height": 50 } }
            ]
          }]
        }]
        """#)
        let dom = try #require(ListDetector.detect(tree: tree).first)
        #expect(dom.bbox.x == 16)
        #expect(dom.bbox.y == 100)
        #expect(dom.bbox.width == 280)         // widest cell
        #expect(dom.bbox.height == 150)        // 250 - 100
    }
}