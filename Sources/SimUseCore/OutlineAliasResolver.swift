// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Resolves `@N` / `#N` / `#N@M` selectors against the alias cache
/// written by the most recent `describe-ui` run for a given UDID.
///
/// The resolver is deliberately stateless and does no drift detection:
/// it looks up the cached center point and hands it back. Callers
/// translate that into a tap / swipe / type coordinate. See
/// `DESCRIBE_UI_OUTLINE.md` §5 for the normative behavior.
public enum OutlineAliasResolver {
    public enum Kind { case at, list }

    /// Three-way classification of the positional alias argument.
    /// - `.at(N)` — `@N`, resolved against the cached outline by
    ///   position index.
    /// - `.list(index, scope)` — `#N` or `#N@M`. `scope == 1` means the
    ///   bare `#N` (dominant list) form; `scope >= 2` means a non-dominant
    ///   list scoped via `@M`.
    /// - `.id(String)` — `#<non-numeric>`, treated as an AXUniqueId
    ///   selector. Consumers route these through the normal live-AX
    ///   resolver the way `tap --id` already does.
    public enum Parsed: Equatable {
        case at(Int)
        case list(index: Int, scope: Int)
        case id(String)
    }

    public struct Resolved {
        public let point: (x: Double, y: Double)
        public let kind: Kind
        /// For `.at` this is the `@N` number; for `.list` this is the
        /// cell index (`N` in `#N` / `#N@M`).
        public let number: Int
        /// Set only for `.list` resolutions. `1` for the dominant list
        /// (bare `#N`); `>= 2` for scoped `#N@M`.
        public let scope: Int?
        public let role: String
        public let label: String

        /// Human-readable phrase used in tap/swipe success lines and in
        /// log output. Keeps the resolved identity visible so the user
        /// can spot "this alias points at the wrong thing" from the
        /// command trace alone.
        public var humanDescription: String {
            let token: String
            switch kind {
            case .at:
                token = "@\(number)"
            case .list:
                if let scope, scope > 1 {
                    token = "#\(number)@\(scope)"
                } else {
                    token = "#\(number)"
                }
            }
            return "\(token) (\(role) \"\(label)\") at (\(Int(point.x)), \(Int(point.y)))"
        }
    }

    public enum ResolutionError: LocalizedError {
        case empty
        case malformed(String)
        case unknownPrefix(Character)
        case atOutOfRange(number: Int, snapshot: OutlineCache.Payload)
        case listUnsupported
        case listScopeOutOfRange(scope: Int, snapshot: OutlineCache.Payload)
        case listIndexOutOfRange(scope: Int, index: Int, snapshot: OutlineCache.Payload)
        /// `#<id>` aliases are resolved live through the AX tree, not
        /// through the outline cache. Callers pattern-match on this
        /// error to route to the standard `--id`-style resolver.
        case idNotCacheable(value: String)

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "Alias must be `@N`, `#N`, `#N@M`, or `#<identifier>`."
            case .malformed(let raw):
                return "Alias '\(raw)' is not valid — expected `@N`, `#N`, `#N@M`, or `#<identifier>`."
            case .unknownPrefix(let char):
                return "Unknown alias prefix '\(char)'. Use `@N` (outline index), `#N` (dominant list), `#N@M` (scoped list), or `#<identifier>` (AXUniqueId)."
            case .atOutOfRange(let number, let snapshot):
                let atMax = snapshot.entries.map(\.aliases.at).max() ?? 0
                return "Snapshot has entries @1..@\(atMax); requested @\(number). Last captured at \(snapshot.capturedAt)."
            case .listUnsupported:
                return "No list clusters in last snapshot. Use @N, #<identifier>, --label, or re-run describe-ui."
            case .listScopeOutOfRange(let scope, let snapshot):
                let scopeMax = snapshot.entries.compactMap { $0.aliases.list?.scope }.max() ?? 0
                if scope == 1 {
                    return "No dominant list in last snapshot (captured \(snapshot.capturedAt)). Use @N, #<identifier>, --label, or re-run describe-ui."
                }
                return "Snapshot has list scopes @1..@\(scopeMax); requested @\(scope). Last captured at \(snapshot.capturedAt)."
            case .listIndexOutOfRange(let scope, let index, let snapshot):
                let cellMax = snapshot.entries
                    .compactMap { $0.aliases.list }
                    .filter { $0.scope == scope }
                    .map(\.index)
                    .max() ?? 0
                if scope == 1 {
                    return "Dominant list has cells #1..#\(cellMax); requested #\(index). Last captured at \(snapshot.capturedAt)."
                }
                return "List scope @\(scope) has cells #1..#\(cellMax); requested #\(index). Last captured at \(snapshot.capturedAt)."
            case .idNotCacheable(let value):
                return "#\(value) is an AXUniqueId selector and must be resolved through the live accessibility tree; pass it to the caller's `--id` path."
            }
        }
    }

    /// Classify the raw argument without hitting disk. The resolver
    /// itself only handles cache-backed cases; `.id` aliases are
    /// returned to the caller to route through the normal live-AX
    /// selector path. Returns `nil` if the input does not look like an
    /// alias at all (caller can then treat it as a non-alias arg).
    public static func parse(_ raw: String) -> Parsed? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        let rest = String(trimmed.dropFirst())
        guard !rest.isEmpty else { return nil }
        switch first {
        case "@":
            guard let n = Int(rest), n > 0 else { return nil }
            return .at(n)
        case "#":
            // Split once on '@'. If the left side parses as positive Int,
            // it is a list selector — either dominant (`#N`, scope=1) or
            // scoped (`#N@M`). Otherwise the whole `rest` is an
            // AXUniqueId, including any `@` characters it might contain.
            if let atIdx = rest.firstIndex(of: "@") {
                let cellPart = String(rest[..<atIdx])
                let scopePart = String(rest[rest.index(after: atIdx)...])
                guard let cell = Int(cellPart), cell > 0 else {
                    // Left side isn't an integer → treat the whole token
                    // as an AXUniqueId. `#feed@home` resolves as id
                    // "feed@home" rather than a malformed list selector.
                    return .id(rest)
                }
                guard let scope = Int(scopePart), scope > 0 else {
                    // Cell parsed but scope didn't — refuse to fall back
                    // to id, that would silently change semantics. Caller
                    // should report malformed.
                    return nil
                }
                return .list(index: cell, scope: scope)
            }
            if let n = Int(rest), n > 0 {
                return .list(index: n, scope: 1)
            }
            return .id(rest)
        default:
            return nil
        }
    }

    /// `home` is pluggable so tests can isolate cache storage; production
    /// callers use the default user home directory.
    ///
    /// Only cache-backed forms are resolved here. Pass in a parsed
    /// `.at` or `.list` alias (by passing the raw string that parses to
    /// one of those). `.id(_)` aliases throw `ResolutionError.idNotCacheable`
    /// — callers route those through the live-AX resolver.
    public static func resolve(
        _ raw: String,
        udid: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Resolved {
        try resolveWithPayload(raw, udid: udid, home: home).resolved
    }

    /// Like `resolve`, but also surfaces the matched cache entry and the
    /// whole snapshot payload. HID consumers need them for orientation
    /// calibration: the entry's frame is the primary probe discriminator
    /// and the snapshot screen size seeds the candidate ordering.
    public static func resolveWithPayload(
        _ raw: String,
        udid: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> (resolved: Resolved, entry: OutlineCache.Payload.Entry, payload: OutlineCache.Payload) {
        guard let parsed = parse(raw) else {
            // Distinguish "empty" from "malformed" for a more helpful
            // error than a single catch-all.
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw ResolutionError.empty
            }
            if let first = trimmed.first, first != "@" && first != "#" {
                throw ResolutionError.unknownPrefix(first)
            }
            throw ResolutionError.malformed(raw)
        }

        switch parsed {
        case .id(let value):
            throw ResolutionError.idNotCacheable(value: value)
        case .at, .list:
            break
        }

        let payload: OutlineCache.Payload
        do {
            payload = try OutlineCache.read(udid: udid, home: home)
        } catch let error as OutlineCache.ReadError {
            throw error
        }

        switch parsed {
        case .at(let n):
            guard let entry = payload.entries.first(where: { $0.aliases.at == n }) else {
                throw ResolutionError.atOutOfRange(number: n, snapshot: payload)
            }
            let resolved = Resolved(
                point: (x: Double(entry.x), y: Double(entry.y)),
                kind: .at,
                number: n,
                scope: nil,
                role: entry.role,
                label: entry.label
            )
            return (resolved, entry, payload)

        case .list(let index, let scope):
            // First check the snapshot has *any* list aliases at all —
            // before list detection ships, every snapshot lands here and
            // we want to surface the friendlier "no list clusters"
            // message instead of an out-of-range error.
            let anyListAliased = payload.entries.contains { $0.aliases.list != nil }
            guard anyListAliased else {
                throw ResolutionError.listUnsupported
            }

            // Scope must exist before we look for the cell index.
            let scopeExists = payload.entries.contains { $0.aliases.list?.scope == scope }
            guard scopeExists else {
                throw ResolutionError.listScopeOutOfRange(scope: scope, snapshot: payload)
            }

            guard let entry = payload.entries.first(where: {
                guard let list = $0.aliases.list else { return false }
                return list.scope == scope && list.index == index
            }) else {
                throw ResolutionError.listIndexOutOfRange(scope: scope, index: index, snapshot: payload)
            }

            let resolved = Resolved(
                point: (x: Double(entry.x), y: Double(entry.y)),
                kind: .list,
                number: index,
                scope: scope,
                role: entry.role,
                label: entry.label
            )
            return (resolved, entry, payload)

        case .id:
            // Already handled above; unreachable in practice.
            throw ResolutionError.idNotCacheable(value: raw)
        }
    }

    /// Lightweight check used by `validate()` — returns true if the
    /// argument looks like an alias so the command can reject conflicting
    /// selectors early without actually hitting the cache. Accepts any
    /// of `@N`, `#N`, `#N@M` (positive integers), or `#<non-numeric>`
    /// (AXUniqueId).
    public static func looksLikeAlias(_ raw: String) -> Bool {
        parse(raw) != nil
    }
}