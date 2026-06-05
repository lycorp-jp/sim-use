// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

private func tempHome() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sim-use-alias-resolver-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func plantCache(udid: String, home: URL, entries: [OutlineCache.Payload.Entry]) throws {
    let payload = OutlineCache.Payload(
        version: 1,
        udid: udid,
        capturedAt: "2026-04-22T00:00:00Z",
        screen: OutlineCache.Payload.Size(width: 400, height: 800),
        entries: entries
    )
    try OutlineCache.writePayload(payload, udid: udid, home: home)
}

// MARK: - Syntax

@Suite("OutlineAliasResolver Looks Like Alias")
struct OutlineAliasResolverSyntaxTests {
    @Test("@N / #N / #N@M / #<id> shapes are recognised")
    func recognised() {
        #expect(OutlineAliasResolver.looksLikeAlias("@5"))
        #expect(OutlineAliasResolver.looksLikeAlias("#12"))
        #expect(OutlineAliasResolver.looksLikeAlias("#3@2"))
        #expect(OutlineAliasResolver.looksLikeAlias(" @3 "))
        #expect(OutlineAliasResolver.looksLikeAlias("#userhome.favoriteButton"))
        #expect(OutlineAliasResolver.looksLikeAlias("#camelCaseId"))
    }

    @Test("non-alias shapes are rejected")
    func rejected() {
        #expect(!OutlineAliasResolver.looksLikeAlias("5"))
        #expect(!OutlineAliasResolver.looksLikeAlias("@"))
        #expect(!OutlineAliasResolver.looksLikeAlias("#"))
        #expect(!OutlineAliasResolver.looksLikeAlias("@abc"))
        #expect(!OutlineAliasResolver.looksLikeAlias("--label=Go"))
    }

    @Test("malformed scope is rejected (not silently treated as id)")
    func malformedScope() {
        // Cell parsed but scope didn't — must NOT fall back to .id, that
        // would silently change semantics. parse() returns nil so resolve
        // throws .malformed.
        #expect(OutlineAliasResolver.parse("#3@") == nil)
        #expect(OutlineAliasResolver.parse("#3@abc") == nil)
        #expect(OutlineAliasResolver.parse("#3@0") == nil)
        #expect(OutlineAliasResolver.parse("#3@-1") == nil)
    }

    @Test("parse classifies @N, #N, #N@M, and #<id>")
    func parseDispatch() {
        #expect(OutlineAliasResolver.parse("@7") == .at(7))
        #expect(OutlineAliasResolver.parse("#3") == .list(index: 3, scope: 1))
        #expect(OutlineAliasResolver.parse("#3@1") == .list(index: 3, scope: 1))
        #expect(OutlineAliasResolver.parse("#2@4") == .list(index: 2, scope: 4))
        #expect(OutlineAliasResolver.parse("#settingsButton") == .id("settingsButton"))
        #expect(OutlineAliasResolver.parse("#user.id.1") == .id("user.id.1"))
        // `@` inside an AXUniqueId is preserved verbatim — we don't try
        // to parse it as `#N@M` if the left side isn't an integer.
        #expect(OutlineAliasResolver.parse("#feed@home") == .id("feed@home"))
    }
}

// MARK: - @N resolution

@Suite("OutlineAliasResolver @N")
struct OutlineAliasResolverAtTests {
    @Test("resolves @N to the cached center point")
    func happyPath() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try plantCache(udid: "U", home: home, entries: [
            OutlineCache.Payload.Entry(
                aliases: Outline.Aliases(at: 1),
                role: "Button", label: "Go",
                x: 50, y: 60, w: 40, h: 40
            ),
            OutlineCache.Payload.Entry(
                aliases: Outline.Aliases(at: 2),
                role: "Tab", label: "Home",
                x: 100, y: 700, w: 80, h: 50
            ),
        ])

        let resolved = try OutlineAliasResolver.resolve("@2", udid: "U", home: home)
        #expect(resolved.point.x == 100)
        #expect(resolved.point.y == 700)
        #expect(resolved.kind == .at)
        #expect(resolved.role == "Tab")
        #expect(resolved.scope == nil)
    }

    @Test("@N out of range emits a readable error")
    func outOfRange() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try plantCache(udid: "U", home: home, entries: [
            OutlineCache.Payload.Entry(
                aliases: Outline.Aliases(at: 1),
                role: "Button", label: "Go",
                x: 50, y: 60, w: 40, h: 40
            ),
        ])
        do {
            _ = try OutlineAliasResolver.resolve("@99", udid: "U", home: home)
            Issue.record("expected throw")
        } catch let error as OutlineAliasResolver.ResolutionError {
            if case .atOutOfRange(let number, _) = error {
                #expect(number == 99)
            } else {
                Issue.record("expected atOutOfRange, got \(error)")
            }
        }
    }
}

// MARK: - #N / #N@M resolution

@Suite("OutlineAliasResolver #N and #N@M")
struct OutlineAliasResolverListTests {
    /// Build a cache with two lists: dominant (scope=1, 3 cells) and a
    /// secondary (scope=2, 2 cells). Mirrors the Share-picker example in
    /// DESCRIBE_UI_OUTLINE.md §2.7.
    private func twoListCache(home: URL) throws {
        try plantCache(udid: "U", home: home, entries: [
            OutlineCache.Payload.Entry(
                aliases: Outline.Aliases(at: 5, list: Outline.ListAlias(scope: 1, index: 1)),
                role: "Cell", label: "Alice",
                x: 200, y: 210, w: 402, h: 59
            ),
            OutlineCache.Payload.Entry(
                aliases: Outline.Aliases(at: 6, list: Outline.ListAlias(scope: 1, index: 2)),
                role: "Cell", label: "Bob",
                x: 200, y: 269, w: 402, h: 59
            ),
            OutlineCache.Payload.Entry(
                aliases: Outline.Aliases(at: 7, list: Outline.ListAlias(scope: 1, index: 3)),
                role: "Cell", label: "Carol",
                x: 200, y: 328, w: 402, h: 59
            ),
            OutlineCache.Payload.Entry(
                aliases: Outline.Aliases(at: 9, list: Outline.ListAlias(scope: 2, index: 1)),
                role: "Cell", label: "Project Phoenix",
                x: 200, y: 490, w: 402, h: 59
            ),
            OutlineCache.Payload.Entry(
                aliases: Outline.Aliases(at: 10, list: Outline.ListAlias(scope: 2, index: 2)),
                role: "Cell", label: "Lunch Club",
                x: 200, y: 549, w: 402, h: 59
            ),
        ])
    }

    @Test("#N reports listUnsupported when no list aliases exist")
    func unsupported() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try plantCache(udid: "U", home: home, entries: [
            OutlineCache.Payload.Entry(
                aliases: Outline.Aliases(at: 1),
                role: "Button", label: "Go",
                x: 50, y: 60, w: 40, h: 40
            ),
        ])

        do {
            _ = try OutlineAliasResolver.resolve("#2", udid: "U", home: home)
            Issue.record("expected throw")
        } catch let error as OutlineAliasResolver.ResolutionError {
            if case .listUnsupported = error { return }
            Issue.record("expected listUnsupported, got \(error)")
        }
    }

    @Test("#N resolves to the dominant list cell (scope=1)")
    func dominantHappyPath() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try twoListCache(home: home)

        let resolved = try OutlineAliasResolver.resolve("#2", udid: "U", home: home)
        #expect(resolved.kind == .list)
        #expect(resolved.number == 2)
        #expect(resolved.scope == 1)
        #expect(resolved.label == "Bob")
        #expect(resolved.point.x == 200)
        #expect(resolved.point.y == 269)
    }

    @Test("#N@1 is a synonym for bare #N")
    func dominantSynonym() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try twoListCache(home: home)

        let bare = try OutlineAliasResolver.resolve("#3", udid: "U", home: home)
        let scoped = try OutlineAliasResolver.resolve("#3@1", udid: "U", home: home)
        #expect(bare.point.x == scoped.point.x)
        #expect(bare.point.y == scoped.point.y)
        #expect(bare.label == scoped.label)
    }

    @Test("#N@M resolves to a non-dominant list cell")
    func scopedHappyPath() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try twoListCache(home: home)

        let resolved = try OutlineAliasResolver.resolve("#2@2", udid: "U", home: home)
        #expect(resolved.kind == .list)
        #expect(resolved.number == 2)
        #expect(resolved.scope == 2)
        #expect(resolved.label == "Lunch Club")
        #expect(resolved.point.x == 200)
        #expect(resolved.point.y == 549)
    }

    @Test("#N out-of-range in dominant list reports listIndexOutOfRange")
    func dominantIndexOutOfRange() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try twoListCache(home: home)

        do {
            _ = try OutlineAliasResolver.resolve("#99", udid: "U", home: home)
            Issue.record("expected throw")
        } catch let error as OutlineAliasResolver.ResolutionError {
            if case .listIndexOutOfRange(let scope, let index, _) = error {
                #expect(scope == 1)
                #expect(index == 99)
            } else {
                Issue.record("expected listIndexOutOfRange, got \(error)")
            }
        }
    }

    @Test("#N@M scope out of range reports listScopeOutOfRange")
    func scopeOutOfRange() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try twoListCache(home: home)

        do {
            _ = try OutlineAliasResolver.resolve("#1@5", udid: "U", home: home)
            Issue.record("expected throw")
        } catch let error as OutlineAliasResolver.ResolutionError {
            if case .listScopeOutOfRange(let scope, _) = error {
                #expect(scope == 5)
            } else {
                Issue.record("expected listScopeOutOfRange, got \(error)")
            }
        }
    }

    @Test("#N@M cell index out of range in non-dominant list reports listIndexOutOfRange")
    func scopedIndexOutOfRange() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try twoListCache(home: home)

        do {
            _ = try OutlineAliasResolver.resolve("#9@2", udid: "U", home: home)
            Issue.record("expected throw")
        } catch let error as OutlineAliasResolver.ResolutionError {
            if case .listIndexOutOfRange(let scope, let index, _) = error {
                #expect(scope == 2)
                #expect(index == 9)
            } else {
                Issue.record("expected listIndexOutOfRange, got \(error)")
            }
        }
    }

    @Test("malformed alias #3@ throws .malformed")
    func malformedThrows() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try twoListCache(home: home)

        do {
            _ = try OutlineAliasResolver.resolve("#3@", udid: "U", home: home)
            Issue.record("expected throw")
        } catch let error as OutlineAliasResolver.ResolutionError {
            if case .malformed = error { return }
            Issue.record("expected malformed, got \(error)")
        }
    }
}

// MARK: - #<id> routing

@Suite("OutlineAliasResolver #<id>")
struct OutlineAliasResolverIDTests {
    @Test("resolve refuses to cache-resolve #<id> and surfaces idNotCacheable")
    func idNotCacheable() throws {
        // `#<id>` must be resolved through the live AX tree, not the
        // cache. The error is the signal Tap uses to fall through to
        // AccessibilityPoller's --id path.
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try plantCache(udid: "U", home: home, entries: [
            OutlineCache.Payload.Entry(
                aliases: Outline.Aliases(at: 1),
                role: "Button", label: "Go",
                x: 50, y: 60, w: 40, h: 40
            ),
        ])

        do {
            _ = try OutlineAliasResolver.resolve("#userhome.favoriteButton", udid: "U", home: home)
            Issue.record("expected idNotCacheable")
        } catch let error as OutlineAliasResolver.ResolutionError {
            if case .idNotCacheable(let value) = error {
                #expect(value == "userhome.favoriteButton")
            } else {
                Issue.record("expected idNotCacheable, got \(error)")
            }
        }
    }

    @Test("AXUniqueId carrying '@' still routes through #<id>")
    func idWithAtSign() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try plantCache(udid: "U", home: home, entries: [
            OutlineCache.Payload.Entry(
                aliases: Outline.Aliases(at: 1),
                role: "Button", label: "Go",
                x: 50, y: 60, w: 40, h: 40
            ),
        ])

        do {
            _ = try OutlineAliasResolver.resolve("#feed@home", udid: "U", home: home)
            Issue.record("expected idNotCacheable")
        } catch let error as OutlineAliasResolver.ResolutionError {
            if case .idNotCacheable(let value) = error {
                #expect(value == "feed@home")
            } else {
                Issue.record("expected idNotCacheable, got \(error)")
            }
        }
    }
}

// MARK: - Missing cache

@Suite("OutlineAliasResolver Missing Cache")
struct OutlineAliasResolverMissingTests {
    @Test("no snapshot on disk surfaces the cache-missing error")
    func missing() {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        do {
            _ = try OutlineAliasResolver.resolve("@1", udid: "NOPE", home: home)
            Issue.record("expected throw")
        } catch let error as OutlineCache.ReadError {
            if case .missing = error { return }
            Issue.record("expected missing, got \(error)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}