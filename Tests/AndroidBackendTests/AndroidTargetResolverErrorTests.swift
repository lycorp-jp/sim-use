// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend
import SimUseCore

/// Behavioral tests for `AndroidTargetResolver`'s alias error path.
///
/// The cache-backed alias forms (`@N` / `#N` / `#N@M`) now delegate to
/// `OutlineAliasResolver` in `SimUseCore`, so we want to confirm two
/// things from the Android side:
///
/// 1. The iOS-shape, list-aware error messages propagate verbatim —
///    no Android-specific wrapping that would re-flatten them back to a
///    generic "alias not found".
/// 2. The `#<id>` branch still routes around the cache via the live
///    AX-tree helper (`resolveIDAlias`) unchanged by the refactor.
final class AndroidTargetResolverErrorTests: XCTestCase {

    private func tempHome() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-android-target-resolver-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Plant a snapshot with a single `@1` entry and one dominant-list
    /// cell `#1`. Lets the tests pick which alias to throw at it without
    /// re-defining the schema each time.
    private func plantCache(home: URL, udid: String) throws {
        let payload = OutlineCache.Payload(
            version: 1,
            udid: udid,
            capturedAt: "2026-05-21T00:00:00Z",
            screen: OutlineCache.Payload.Size(width: 1080, height: 2400),
            entries: [
                OutlineCache.Payload.Entry(
                    aliases: Outline.Aliases(at: 1, list: nil),
                    role: "Button",
                    label: "OK",
                    x: 100,
                    y: 200,
                    w: 100,
                    h: 50
                ),
                OutlineCache.Payload.Entry(
                    aliases: Outline.Aliases(
                        at: 2,
                        list: Outline.ListAlias(scope: 1, index: 1)
                    ),
                    role: "Cell",
                    label: "Row A",
                    x: 540,
                    y: 400,
                    w: 1080,
                    h: 120
                ),
            ]
        )
        try OutlineCache.writePayload(payload, udid: udid, home: home)
    }

    // The refactor's main contract: cache-backed errors come straight
    // from `OutlineAliasResolver.ResolutionError`, not a flattened
    // Android-side `aliasNotFound`. We assert on the case shape rather
    // than on the message wording so message tweaks in SimUseCore don't
    // ripple here — that file owns the prose.

    func testAtOutOfRangeMessageMentionsAtRange() throws {
        // The shared resolver doesn't take a controller, so we call it
        // directly with the planted cache instead of `AndroidTargetResolver.resolve`
        // (which requires an AndroidDeviceController to even be
        // constructed). Behavior is equivalent: the Android resolver's
        // first step inside the alias branch is exactly this call.
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let udid = "emulator-test"
        try plantCache(home: home, udid: udid)

        XCTAssertThrowsError(
            try OutlineAliasResolver.resolve("@9", udid: udid, home: home)
        ) { error in
            guard case OutlineAliasResolver.ResolutionError.atOutOfRange = error else {
                return XCTFail("expected .atOutOfRange, got \(error)")
            }
            let message = error.localizedDescription
            XCTAssertTrue(
                message.contains("@1..@2"),
                "expected '@1..@2' range hint; got: \(message)"
            )
        }
    }

    func testListIndexOutOfRangeMentionsCellRange() throws {
        // Regression target for the user-reported wording bug: before
        // this refactor, `#999` against a dominant list bottomed out in
        // Android's `aliasNotFound` and surfaced "available `@N` range"
        // — the *wrong axis*. The shared resolver instead reports
        // "Dominant list has cells #1..#N".
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let udid = "emulator-test"
        try plantCache(home: home, udid: udid)

        XCTAssertThrowsError(
            try OutlineAliasResolver.resolve("#999", udid: udid, home: home)
        ) { error in
            guard case OutlineAliasResolver.ResolutionError.listIndexOutOfRange = error else {
                return XCTFail("expected .listIndexOutOfRange, got \(error)")
            }
            let message = error.localizedDescription
            XCTAssertTrue(
                message.contains("Dominant list"),
                "expected 'Dominant list' wording; got: \(message)"
            )
            XCTAssertTrue(
                message.contains("#1"),
                "expected cell range hint; got: \(message)"
            )
        }
    }

    func testListScopeOutOfRangeMentionsScopeRange() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let udid = "emulator-test"
        try plantCache(home: home, udid: udid)

        XCTAssertThrowsError(
            try OutlineAliasResolver.resolve("#1@99", udid: udid, home: home)
        ) { error in
            guard case OutlineAliasResolver.ResolutionError.listScopeOutOfRange = error else {
                return XCTFail("expected .listScopeOutOfRange, got \(error)")
            }
            let message = error.localizedDescription
            XCTAssertTrue(
                message.contains("list scopes"),
                "expected 'list scopes' wording; got: \(message)"
            )
        }
    }

    func testListUnsupportedWhenNoListAliasesPresent() throws {
        // Snapshot has only `@N` entries — no list aliases at all. `#1`
        // should report "no list clusters" rather than a generic
        // not-found.
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let udid = "emulator-test"
        let payload = OutlineCache.Payload(
            version: 1,
            udid: udid,
            capturedAt: "2026-05-21T00:00:00Z",
            screen: OutlineCache.Payload.Size(width: 1080, height: 2400),
            entries: [
                OutlineCache.Payload.Entry(
                    aliases: Outline.Aliases(at: 1, list: nil),
                    role: "Button",
                    label: "OK",
                    x: 100, y: 200, w: 100, h: 50
                ),
            ]
        )
        try OutlineCache.writePayload(payload, udid: udid, home: home)

        XCTAssertThrowsError(
            try OutlineAliasResolver.resolve("#1", udid: udid, home: home)
        ) { error in
            guard case OutlineAliasResolver.ResolutionError.listUnsupported = error else {
                return XCTFail("expected .listUnsupported, got \(error)")
            }
        }
    }

    /// `#<id>` aliases resolve through the AX tree via
    /// `AndroidSelectorResolver` rather than the outline cache. The
    /// uniqueId-only entry returns its frame center along with an
    /// `alias #<id> → role "label"` description matching the iOS
    /// `.id` branch's success-line shape.
    func testResolveIDAliasMatchesUniqueId() throws {
        let entries: [Outline.Entry] = [
            Outline.Entry(
                aliases: .init(at: 1),
                role: "Button",
                label: "Chats",
                frame: .init(x: 240, y: 2190, width: 168, height: 147),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: "bnb_tab_chat",
                value: nil,
                resourceId: nil,
                hint: nil
            ),
            Outline.Entry(
                aliases: .init(at: 2),
                role: "Button",
                label: "Home",
                frame: .init(x: 0, y: 2190, width: 168, height: 147),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: "bnb_tab_home",
                value: nil,
                resourceId: nil,
                hint: nil
            ),
        ]

        let target = try AndroidTargetResolver.resolveIDAlias(
            uniqueId: "bnb_tab_chat",
            selector: AndroidSelector(),
            entries: entries,
            screen: nil
        )

        XCTAssertEqual(target.x, 240 + 168 / 2)
        XCTAssertEqual(target.y, 2190 + 147 / 2)
        XCTAssertTrue(
            target.description.contains("#bnb_tab_chat"),
            "expected uniqueId in description; got \(target.description)"
        )
        XCTAssertTrue(target.description.contains("\"Chats\""))
    }

    /// When `#<id>` doesn't match anything on screen the live selector
    /// resolver surfaces its standard `.noMatch` error (with candidate
    /// hints) — the two paths have different shapes on purpose: cache
    /// misses live in `OutlineAliasResolver.ResolutionError`; AX-tree
    /// misses live in `AndroidSelectorError` and already enumerate the
    /// ids actually on screen, which is the more useful fix-it.
    func testResolveIDAliasUnknownIDThrowsSelectorNoMatch() {
        let entries: [Outline.Entry] = [
            Outline.Entry(
                aliases: .init(at: 1),
                role: "Button",
                label: "Chats",
                frame: .init(x: 240, y: 2190, width: 168, height: 147),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: "bnb_tab_chat",
                value: nil,
                resourceId: nil,
                hint: nil
            ),
        ]

        XCTAssertThrowsError(
            try AndroidTargetResolver.resolveIDAlias(
                uniqueId: "does_not_exist",
                selector: AndroidSelector(),
                entries: entries,
                screen: nil
            )
        ) { error in
            guard case AndroidSelectorError.noMatch = error else {
                return XCTFail("expected AndroidSelectorError.noMatch, got \(error)")
            }
        }
    }
}