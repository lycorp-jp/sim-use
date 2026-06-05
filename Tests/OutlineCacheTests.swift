// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

private func makeOutline() -> Outline {
    Outline(
        text: "App: Demo  200x400\n\n[Top  y<120]\n  @1  Button  \"Go\"  (10,20 40x40)\n",
        entries: [
            Outline.Entry(
                aliases: Outline.Aliases(at: 1),
                role: "Button",
                label: "Go",
                frame: Outline.Frame(x: 10, y: 20, width: 40, height: 40),
                region: Outline.Region(kind: "Top"),
                states: []
            ),
            Outline.Entry(
                aliases: Outline.Aliases(at: 2),
                role: "Tab",
                label: "Home",
                frame: Outline.Frame(x: 0, y: 780, width: 100, height: 50),
                region: Outline.Region(kind: "Group", label: "TabBar"),
                states: ["selected"]
            ),
        ],
        screen: Outline.Frame(x: 0, y: 0, width: 200, height: 400),
        appLabel: "Demo"
    )
}

private func tempHome() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sim-use-outline-cache-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("OutlineCache Payload Construction")
struct OutlineCachePayloadTests {
    @Test("payload precomputes the frame center and preserves aliases")
    func payloadCenters() {
        let payload = OutlineCache.makePayload(
            outline: makeOutline(),
            udid: "UDID",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(payload.version == 1)
        #expect(payload.udid == "UDID")
        #expect(payload.screen.width == 200 && payload.screen.height == 400)
        #expect(payload.entries.count == 2)

        let first = payload.entries[0]
        #expect(first.x == 30 && first.y == 40)   // center of (10,20 40x40)
        #expect(first.w == 40 && first.h == 40)
        #expect(first.aliases.at == 1)
        #expect(first.aliases.list == nil)

        let second = payload.entries[1]
        #expect(second.x == 50 && second.y == 805) // center of (0,780 100x50)
        #expect(second.aliases.at == 2)
    }

    @Test("encoded JSON omits absent optionals")
    func encodedShape() throws {
        let payload = OutlineCache.makePayload(
            outline: makeOutline(),
            udid: "UDID"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let text = String(decoding: data, as: UTF8.self)
        // aliases.list is omitted — no `"list"` key for the v1 at-only entries.
        #expect(!text.contains("\"list\""))
        // Region labels that are non-nil are serialised normally; the
        // alias cache does not surface region on entries, so absence of
        // a `region` key is fine too.
        #expect(!text.contains("\"region\""))
    }

    @Test("nested ListAlias serialises as { scope, index }")
    func nestedListAliasShape() throws {
        let outline = Outline(
            text: "App: Demo  100x100\n",
            entries: [
                Outline.Entry(
                    aliases: Outline.Aliases(at: 1, list: Outline.ListAlias(scope: 1, index: 1)),
                    role: "Cell",
                    label: "Alice",
                    frame: Outline.Frame(x: 0, y: 0, width: 100, height: 50),
                    region: Outline.Region(kind: "Content"),
                    states: []
                ),
                Outline.Entry(
                    aliases: Outline.Aliases(at: 2, list: Outline.ListAlias(scope: 2, index: 1)),
                    role: "Cell",
                    label: "Project Phoenix",
                    frame: Outline.Frame(x: 0, y: 60, width: 100, height: 50),
                    region: Outline.Region(kind: "Content"),
                    states: []
                ),
            ],
            screen: Outline.Frame(x: 0, y: 0, width: 100, height: 100),
            appLabel: "Demo"
        )
        let payload = OutlineCache.makePayload(outline: outline, udid: "U")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"list\":{\"index\":1,\"scope\":1}"))
        #expect(text.contains("\"list\":{\"index\":1,\"scope\":2}"))
    }
}

@Suite("OutlineCache Round Trip")
struct OutlineCacheRoundTripTests {
    @Test("write then read yields an equal payload")
    func writeThenRead() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let captured = Date(timeIntervalSince1970: 1_700_000_123)
        try OutlineCache.write(
            outline: makeOutline(),
            udid: "UDID-A",
            capturedAt: captured,
            home: home
        )
        let payload = try OutlineCache.read(udid: "UDID-A", home: home)
        #expect(payload.entries.count == 2)
        #expect(payload.udid == "UDID-A")
        #expect(payload.entries[0].label == "Go")
        #expect(payload.entries[1].aliases.at == 2)
    }

    @Test("separate UDIDs keep distinct caches")
    func perUDIDIsolation() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try OutlineCache.write(outline: makeOutline(), udid: "A", home: home)
        var otherOutline = makeOutline()
        otherOutline = Outline(
            text: otherOutline.text,
            entries: [
                Outline.Entry(
                    aliases: Outline.Aliases(at: 1),
                    role: "Button",
                    label: "OnlyInB",
                    frame: Outline.Frame(x: 0, y: 0, width: 10, height: 10),
                    region: Outline.Region(kind: "Top"),
                    states: []
                )
            ],
            screen: otherOutline.screen,
            appLabel: otherOutline.appLabel
        )
        try OutlineCache.write(outline: otherOutline, udid: "B", home: home)

        let a = try OutlineCache.read(udid: "A", home: home)
        let b = try OutlineCache.read(udid: "B", home: home)
        #expect(a.entries.count == 2)
        #expect(b.entries.count == 1)
        #expect(b.entries.first?.label == "OnlyInB")
    }
}

@Suite("OutlineCache Errors")
struct OutlineCacheErrorTests {
    @Test("missing cache produces a guided error")
    func missingCache() {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(throws: OutlineCache.ReadError.self) {
            _ = try OutlineCache.read(udid: "nope", home: home)
        }
    }

    @Test("version mismatch triggers versionMismatch")
    func versionMismatch() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let udid = "UDID-V"
        let dir = OutlineCache.directory(for: udid, home: home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bogus = #"{"version": 99, "udid": "UDID-V", "capturedAt": "2026-01-01T00:00:00Z", "screen": {"width": 100, "height": 100}, "entries": []}"#
        try Data(bogus.utf8).write(to: OutlineCache.file(for: udid, home: home))

        do {
            _ = try OutlineCache.read(udid: udid, home: home)
            Issue.record("Expected versionMismatch error")
        } catch let error as OutlineCache.ReadError {
            if case .versionMismatch(_, let got, let expected) = error {
                #expect(got == 99 && expected == 1)
            } else {
                Issue.record("Expected versionMismatch, got \(error)")
            }
        } catch {
            Issue.record("Expected ReadError, got \(error)")
        }
    }

    @Test("corrupt JSON triggers corrupt")
    func corruptJSON() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let udid = "UDID-C"
        let dir = OutlineCache.directory(for: udid, home: home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: OutlineCache.file(for: udid, home: home))

        do {
            _ = try OutlineCache.read(udid: udid, home: home)
            Issue.record("Expected corrupt error")
        } catch let error as OutlineCache.ReadError {
            if case .corrupt = error {
                // pass
            } else {
                Issue.record("Expected corrupt, got \(error)")
            }
        }
    }
}