// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import SimUseCore

final class OutlineEntryCodableTests: XCTestCase {

    func testRoundTripFullEntry() throws {
        let entry = Outline.Entry(
            aliases: .init(at: 5, list: .init(scope: 2, index: 3)),
            role: "Button",
            label: "Submit",
            frame: .init(x: 10, y: 20, width: 100, height: 40),
            region: .init(kind: "TabBar", label: "Bottom"),
            states: ["selected", "value=\"on\""],
            uniqueId: "submit_btn",
            value: "active",
            resourceId: "submit_button",
            hint: "Tap to submit"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(Outline.Entry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }

    func testRoundTripWithOptionalsNil() throws {
        let entry = Outline.Entry(
            aliases: .init(at: 1),
            role: "TextView",
            label: "Hi",
            frame: .init(x: 0, y: 0, width: 1, height: 1),
            region: .init(kind: "Content"),
            states: []
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(Outline.Entry.self, from: data)
        XCTAssertNil(decoded.uniqueId)
        XCTAssertNil(decoded.value)
        XCTAssertNil(decoded.resourceId)
        XCTAssertNil(decoded.hint)
        XCTAssertEqual(decoded, entry)
    }

    func testEncodedJsonUsesResourceIdSnakeCase() throws {
        let entry = Outline.Entry(
            aliases: .init(at: 1),
            role: "Button",
            label: "",
            frame: .init(x: 0, y: 0, width: 1, height: 1),
            region: .init(kind: "Content"),
            states: [],
            resourceId: "x"
        )
        let data = try JSONEncoder().encode(entry)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"resource_id\":\"x\""))
        XCTAssertFalse(text.contains("\"resourceId\""))
    }

    func testDecodesOldEntryWithoutOptionalFields() throws {
        // Legacy iOS V0 entry — no value/resource_id/hint fields.
        let json = """
        {
          "aliases": {"at": 1},
          "role": "Button",
          "label": "OK",
          "frame": {"x": 0, "y": 0, "width": 100, "height": 40},
          "region": {"kind": "Content"},
          "states": []
        }
        """.data(using: .utf8)!
        let entry = try JSONDecoder().decode(Outline.Entry.self, from: json)
        XCTAssertEqual(entry.aliases.at, 1)
        XCTAssertNil(entry.value)
        XCTAssertNil(entry.resourceId)
        XCTAssertNil(entry.hint)
    }

    func testListSummaryCodable() throws {
        let summary = Outline.ListSummary(
            scope: 1,
            cellCount: 5,
            cellHeight: 80,
            containerRole: "List",
            containerLabel: nil,
            bbox: .init(x: 0, y: 100, width: 1080, height: 800),
            score: 1.0
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(Outline.ListSummary.self, from: data)
        XCTAssertEqual(decoded, summary)
    }

    func testAliasesOmitsListWhenNil() throws {
        let aliases = Outline.Aliases(at: 7, list: nil)
        let data = try JSONEncoder().encode(aliases)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("list"))
        XCTAssertTrue(text.contains("\"at\":7"))
    }
}