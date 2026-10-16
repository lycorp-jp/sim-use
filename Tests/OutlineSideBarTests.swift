// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

// iPhone Duo "vertical bar" regions (docs/ai/010-display-routing, S4). An
// iOS 27.1 SDK app on the Duo cover display, and on the inner display in
// landscape, moves its container-owned chrome — back button, trailing
// toolbar items, tab bar — into a bar along one side. The outline groups
// that bar into `[Trailing …]` / `[Leading …]` only on that evidence; every
// other tree renders as before. Fixtures are raw `ui --json` trees captured
// from the Playground `chrome-test` screen (Xcode 27.1 and 27.0 builds) on
// an iPhone Duo / iOS 27.1 and an iPhone 17 / iOS 27.0.

private struct Fixture: Decodable {
    struct Size: Decodable { let width: Double; let height: Double }
    let screen: Size
    let raw: [AccessibilityElement]
}

private func render(_ name: String) throws -> Outline {
    let url = try #require(
        Bundle.module.url(forResource: "Fixtures/outline-side-bars/\(name)", withExtension: "json"),
        "Fixture '\(name).json' not bundled"
    )
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    return OutlineFormatter.render(
        tree: fixture.raw,
        screenSize: (width: fixture.screen.width, height: fixture.screen.height)
    )
}

private extension Outline {
    func regionKind(id: String) -> String? {
        entries.first { $0.uniqueId == id }?.region.kind
    }

    func regionKind(label: String) -> String? {
        entries.first { $0.label == label }?.region.kind
    }

    var sideKinds: Set<String> {
        Set(entries.map(\.region.kind)).intersection(["Leading", "Trailing"])
    }
}

@Suite("Outline side bars")
struct OutlineSideBarTests {
    @Test("the cover display's vertical bar is one Trailing region", arguments: [
        "sdk271-cover-portrait", "sdk271-cover-landscape-left", "sdk271-inner-landscape-left",
    ])
    func trailingBar(fixture: String) throws {
        let outline = try render(fixture)
        #expect(outline.sideKinds == ["Trailing"])
        for id in ["BackButton", "chrome-add"] {
            #expect(outline.regionKind(id: id) == "Trailing", "\(id) belongs to the bar")
        }
        for tab in ["Home", "Search", "Settings"] {
            #expect(outline.entries.contains { $0.label == tab && $0.region.kind == "Trailing" }, "tab \(tab)")
        }
        // Content and horizontal chrome keep their bands.
        #expect(outline.regionKind(id: "chrome-row-inbox") == "Content")
        #expect(outline.regionKind(id: "chrome-edit") == "Top")
        #expect(outline.regionKind(id: "chrome-share") == "Bottom")
        #expect(outline.text.contains("[Trailing  x>="))
    }

    @Test("Settings (UIKit) on the cover: back button and status bar items form the bar")
    func settingsCover() throws {
        // The navigation bar leaves a full-width group behind; it is a
        // container, not content that crosses the bar.
        let outline = try render("settings-cover-general")
        #expect(outline.sideKinds == ["Trailing"])
        #expect(outline.regionKind(id: "BackButton") == "Trailing")
        #expect(outline.regionKind(id: "com.apple.settings.general.about") == "Content")
    }

    @Test("a full-width button row still blocks the bar")
    func fullWidthRowBlocks() throws {
        let children = [
            element("Button", "Back", 16, 50, 44, 44, id: "BackButton"),
            element("Image", "Wi-Fi", 20, 200, 30, 30),
            element("Button", "Wi-Fi", 0, 190, 402, 50),
            element("StaticText", "Wi-Fi", 68, 200, 250, 30),
        ].joined(separator: ",")
        let outline = OutlineFormatter.render(tree: try tree(children))
        #expect(outline.entries.allSatisfy { !["Leading", "Trailing"].contains($0.region.kind) })
    }

    @Test("in landscape-right the cover bar is on the leading edge")
    func leadingBar() throws {
        let outline = try render("sdk271-cover-landscape-right")
        #expect(outline.sideKinds == ["Leading"])
        #expect(outline.regionKind(id: "BackButton") == "Leading")
        #expect(outline.regionKind(id: "chrome-add") == "Leading")
        #expect(outline.regionKind(id: "chrome-row-inbox") == "Content")
        #expect(outline.text.contains("[Leading  x<="))
    }

    @Test("bar entries come last, top to bottom, with aliases in print order")
    func barOrder() throws {
        let outline = try render("sdk271-cover-portrait")
        let kinds = outline.entries.map(\.region.kind)
        let firstBar = try #require(kinds.firstIndex(of: "Trailing"))
        #expect(kinds[firstBar...].allSatisfy { $0 == "Trailing" })
        let bar = outline.entries[firstBar...]
        #expect(bar.map(\.frame.y) == bar.map(\.frame.y).sorted())
        #expect(outline.entries.map(\.aliases.at) == Array(1...outline.entries.count))
        // The text lists the bar after the bands.
        let text = outline.text
        let trailing = try #require(text.range(of: "[Trailing"))
        let bottom = try #require(text.range(of: "[Bottom"))
        #expect(bottom.lowerBound < trailing.lowerBound)
    }

    @Test("horizontal chrome is unchanged", arguments: [
        "sdk271-inner-portrait",
        "sdk270-cover-portrait",
        "sdk270-inner-landscape-left",
        "iphone17-chrome-portrait",
        "iphone17-chrome-landscape-left",
        "iphone17-settings-general",
    ])
    func noBar(fixture: String) throws {
        let outline = try render(fixture)
        #expect(outline.sideKinds.isEmpty)
        #expect(!outline.text.contains("[Trailing") && !outline.text.contains("[Leading"))
    }

    // MARK: - Gating on synthetic trees

    private func tree(_ children: String, width: Int = 402, height: Int = 874) throws -> [AccessibilityElement] {
        let json = """
        [{"type": "Application", "AXLabel": "App", "frame": {"x": 0, "y": 0, "width": \(width), "height": \(height)}, "children": [\(children)]}]
        """
        return try JSONDecoder().decode([AccessibilityElement].self, from: Data(json.utf8))
    }

    private func element(_ type: String, _ label: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int, id: String? = nil) -> String {
        let idPart = id.map { ", \"AXUniqueId\": \"\($0)\"" } ?? ""
        return #"{"type": "\#(type)", "AXLabel": "\#(label)", "frame": {"x": \#(x), "y": \#(y), "width": \#(w), "height": \#(h)}\#(idPart)}"#
    }

    @Test("a back button above leading row icons is not a bar: the rows cross it")
    func rowsCrossTheStrip() throws {
        let children = [
            element("Button", "Back", 16, 50, 44, 44, id: "BackButton"),
            element("Image", "Wi-Fi", 20, 200, 30, 30),
            element("Image", "Bluetooth", 20, 252, 30, 30),
            element("Button", "Wi-Fi", 16, 190, 370, 50),
            element("Button", "Bluetooth", 16, 242, 370, 50),
        ].joined(separator: ",")
        let outline = OutlineFormatter.render(tree: try tree(children))
        #expect(outline.entries.allSatisfy { !["Leading", "Trailing"].contains($0.region.kind) })
    }

    @Test("a sparse screen with no wide content is not a bar")
    func noWideContent() throws {
        let children = [
            element("Button", "Back", 16, 50, 44, 44, id: "BackButton"),
            element("Image", "Logo", 20, 300, 40, 40),
        ].joined(separator: ",")
        let outline = OutlineFormatter.render(tree: try tree(children))
        #expect(outline.entries.allSatisfy { !["Leading", "Trailing"].contains($0.region.kind) })
    }

    @Test("a right-edge column without a back button or tabs is not a bar")
    func noAnchor() throws {
        // A section index or a column of switches on a regular iPhone.
        let children = [
            element("Button", "A", 380, 200, 16, 16),
            element("Button", "B", 380, 220, 16, 16),
            element("Button", "C", 380, 240, 16, 16),
            element("StaticText", "Row", 16, 300, 340, 44),
        ].joined(separator: ",")
        let outline = OutlineFormatter.render(tree: try tree(children))
        #expect(outline.entries.allSatisfy { !["Leading", "Trailing"].contains($0.region.kind) })
    }

    @Test("an edge tab of a horizontal tab bar is not a bar anchor (S4-001)")
    func horizontalTabBarEdge() throws {
        // An ordinary iPhone: five tabs across the bottom, a trailing
        // navigation button and status items above, an empty-state text.
        let tabs = (0..<5).map { element("RadioButton", "Tab \($0)", 10 + 76 * $0, 792, 74, 48) }
        let children = (tabs + [
            element("Button", "More", 346, 62, 36, 36),
            element("Image", "Wi-Fi", 314, 26, 18, 13),
            element("Image", "Battery", 340, 26, 27, 13),
            element("StaticText", "Nothing here yet", 40, 300, 260, 44),
        ]).joined(separator: ",")
        let outline = OutlineFormatter.render(tree: try tree(children))
        #expect(outline.entries.allSatisfy { !["Leading", "Trailing"].contains($0.region.kind) })
    }

    @Test("native top chrome over a centred empty state is not a bar (S4-003)")
    func statusClockAboveBackButton() throws {
        // iPhone 17 top chrome (clock above the back button, both in the
        // top band) with a short centred empty-state label as content.
        let children = [
            element("StaticText", "9:41", 56, 22, 36, 22),
            element("GenericElement", "Dynamic Island", 138, 14, 125, 37),
            element("Image", "Wi-Fi", 314, 26, 18, 13),
            element("Image", "Battery", 340, 26, 27, 13),
            element("Button", "Back", 16, 62, 44, 44, id: "BackButton"),
            element("Heading", "Details", 150, 74, 100, 22),
            element("StaticText", "Nothing here yet", 96, 300, 210, 28),
        ].joined(separator: ",")
        let outline = OutlineFormatter.render(tree: try tree(children))
        #expect(outline.entries.allSatisfy { !["Leading", "Trailing"].contains($0.region.kind) })
        #expect(outline.entries.first { $0.uniqueId == "BackButton" }?.region.kind == "Top")
    }

    @Test("a single tab with unrelated items above it is not a bar")
    func singleTabAnchor() throws {
        let children = [
            element("RadioButton", "Tab", 330, 792, 60, 48),
            element("Button", "More", 346, 62, 36, 36),
            element("StaticText", "Nothing here yet", 40, 300, 260, 44),
        ].joined(separator: ",")
        let outline = OutlineFormatter.render(tree: try tree(children))
        #expect(outline.entries.allSatisfy { !["Leading", "Trailing"].contains($0.region.kind) })
    }

    @Test("an unlabeled group around the bar keeps the bar (S4-002)")
    func wrappedBar() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/outline-side-bars/sdk271-cover-portrait", withExtension: "json"))
        var document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var raw = try #require(document["raw"] as? [[String: Any]])
        var app = raw[0]
        var children = try #require(app["children"] as? [[String: Any]])
        // Move every element of the bar (x >= 384) under one rail group.
        func inBar(_ node: [String: Any]) -> Bool {
            guard let f = node["frame"] as? [String: Any], let x = f["x"] as? Double, let w = f["width"] as? Double else { return false }
            return x >= 384 && w <= 100
        }
        func extract(_ nodes: inout [[String: Any]]) -> [[String: Any]] {
            var taken: [[String: Any]] = []
            nodes = nodes.compactMap { node in
                if inBar(node) { taken.append(node); return nil }
                var node = node
                if var kids = node["children"] as? [[String: Any]] {
                    taken += extract(&kids)
                    node["children"] = kids
                }
                return node
            }
            return taken
        }
        let bar = extract(&children)
        #expect(bar.count >= 5)
        children.append([
            "type": "Group", "AXLabel": "", "children": bar,
            "frame": ["x": 384.0, "y": 0.0, "width": 82.0, "height": 678.0],
        ])
        app["children"] = children
        raw[0] = app
        document["raw"] = raw
        struct Doc: Decodable { let raw: [AccessibilityElement] }
        let wrapped = try JSONDecoder().decode(Doc.self, from: JSONSerialization.data(withJSONObject: document))
        let outline = OutlineFormatter.render(tree: wrapped.raw, screenSize: (width: 466, height: 678))
        #expect(outline.regionKind(id: "BackButton") == "Trailing")
        #expect(outline.regionKind(id: "chrome-add") == "Trailing")
        #expect(outline.entries.filter { $0.role == "RadioButton" }.allSatisfy { $0.region.kind == "Trailing" })
    }

    @Test("a point query (no screen) never has a bar")
    func subtree() throws {
        let json = #"[{"type": "Button", "AXLabel": "Back", "AXUniqueId": "BackButton", "frame": {"x": 399, "y": 179, "width": 38, "height": 38}}]"#
        let outline = OutlineFormatter.render(tree: try JSONDecoder().decode([AccessibilityElement].self, from: Data(json.utf8)))
        #expect(outline.entries.allSatisfy { $0.region.kind == "Content" })
    }
}
