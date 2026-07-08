// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Reads and writes the `@N` / `#N` alias cache used by tap/swipe/type
/// when a positional argument starts with `@` or `#`.
///
/// The cache is a tiny JSON document at `~/.sim-use/<udid>/last-outline.json`
/// written every time `describe-ui` finishes a successful snapshot. Both
/// iOS and Android backends share this code so cross-platform skills can
/// resolve aliases uniformly. See `DESCRIBE_UI_OUTLINE.md` §5 for the
/// normative schema.
public enum OutlineCache {
    public static let currentVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
        public let version: Int
        public let udid: String
        public let capturedAt: String       // ISO-8601, second precision, UTC
        public let screen: Size
        public let entries: [Entry]
        /// Calibrated interface orientation at capture time (iOS
        /// `DisplayOrientation` raw value; nil on Android and in caches
        /// written before the field existed). Diagnostic — coordinates
        /// in `entries` are always UI space regardless.
        public let orientation: String?

        public init(
            version: Int,
            udid: String,
            capturedAt: String,
            screen: Size,
            entries: [Entry],
            orientation: String? = nil
        ) {
            self.version = version
            self.udid = udid
            self.capturedAt = capturedAt
            self.screen = screen
            self.entries = entries
            self.orientation = orientation
        }

        public struct Size: Codable, Equatable, Sendable {
            public let width: Int
            public let height: Int
            public init(width: Int, height: Int) {
                self.width = width
                self.height = height
            }
        }

        public struct Entry: Codable, Equatable, Sendable {
            public let aliases: Outline.Aliases
            public let role: String
            public let label: String
            /// Center-x of the element's frame. Pre-computed so tap can
            /// stay strictly stateless and treat `@N` as a literal
            /// coordinate lookup.
            public let x: Int
            public let y: Int
            /// Full frame width / height preserved for future swipe
            /// commands and caller diagnostics.
            public let w: Int
            public let h: Int

            public init(
                aliases: Outline.Aliases,
                role: String,
                label: String,
                x: Int,
                y: Int,
                w: Int,
                h: Int
            ) {
                self.aliases = aliases
                self.role = role
                self.label = label
                self.x = x
                self.y = y
                self.w = w
                self.h = h
            }
        }
    }

    // MARK: - Paths

    public static func directory(for udid: String, home: URL = homeDirectory) -> URL {
        home
            .appendingPathComponent(".sim-use", isDirectory: true)
            .appendingPathComponent(udid, isDirectory: true)
    }

    public static func file(for udid: String, home: URL = homeDirectory) -> URL {
        directory(for: udid, home: home).appendingPathComponent("last-outline.json")
    }

    // MARK: - Write

    public static func write(
        outline: Outline,
        udid: String,
        capturedAt: Date = Date(),
        orientation: String? = nil,
        home: URL = homeDirectory
    ) throws {
        let payload = makePayload(outline: outline, udid: udid, capturedAt: capturedAt, orientation: orientation)
        try writePayload(payload, udid: udid, home: home)
    }

    public static func makePayload(
        outline: Outline,
        udid: String,
        capturedAt: Date = Date(),
        orientation: String? = nil
    ) -> Payload {
        let entries = outline.entries.map { entry -> Payload.Entry in
            let cx = entry.frame.x + entry.frame.width / 2
            let cy = entry.frame.y + entry.frame.height / 2
            return Payload.Entry(
                aliases: entry.aliases,
                role: entry.role,
                label: entry.label,
                x: cx,
                y: cy,
                w: entry.frame.width,
                h: entry.frame.height
            )
        }
        return Payload(
            version: currentVersion,
            udid: udid,
            capturedAt: isoFormatter.string(from: capturedAt),
            screen: Payload.Size(width: outline.screen.width, height: outline.screen.height),
            entries: entries,
            orientation: orientation
        )
    }

    public static func writePayload(_ payload: Payload, udid: String, home: URL = homeDirectory) throws {
        let dir = directory(for: udid, home: home)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)

        let target = file(for: udid, home: home)
        let tempURL = dir.appendingPathComponent("last-outline.json.\(UUID().uuidString).tmp")
        // `defer` cleans up the temp file even when `replaceItemAt`
        // throws (mid-write power loss, permissions flip on the
        // target dir, etc.). Without this guard the cache directory
        // could accumulate `.tmp` files indefinitely. `try?` is
        // intentional — the temp may already be gone after a
        // successful replace, and the cleanup itself is best-effort.
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try data.write(to: tempURL, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(target, withItemAt: tempURL)
    }

    // MARK: - Read

    public enum ReadError: LocalizedError {
        case missing(path: String, udid: String)
        case corrupt(path: String, underlying: Error)
        case versionMismatch(path: String, got: Int, expected: Int)
        case udidMismatch(path: String, expected: String, got: String)

        public var errorDescription: String? {
            switch self {
            case .missing(_, let udid):
                return "No describe-ui snapshot for UDID \(udid). Run `sim-use describe-ui --udid \(udid)` first."
            case .corrupt(_, let underlying):
                return "Outline cache is corrupt (\(underlying.localizedDescription)). Re-run `sim-use describe-ui`."
            case .versionMismatch(_, let got, let expected):
                return "Outline cache version mismatch (got \(got), expected \(expected)). Re-run `sim-use describe-ui`."
            case .udidMismatch(_, let expected, let got):
                return "Outline cache UDID mismatch (cache: \(got), requested: \(expected)). Re-run `sim-use describe-ui`."
            }
        }
    }

    public static func read(udid: String, home: URL = homeDirectory) throws -> Payload {
        let url = file(for: udid, home: home)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReadError.missing(path: url.path, udid: udid)
        }
        let data: Data
        let payload: Payload
        do {
            data = try Data(contentsOf: url)
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ReadError.corrupt(path: url.path, underlying: error)
        }
        guard payload.version == currentVersion else {
            throw ReadError.versionMismatch(path: url.path, got: payload.version, expected: currentVersion)
        }
        guard payload.udid == udid else {
            throw ReadError.udidMismatch(path: url.path, expected: udid, got: payload.udid)
        }
        return payload
    }

    // MARK: - Helpers

    /// Default `~`. Must stay `public` because every public method
    /// (`directory(for:home:)`, `file(for:home:)`, `read`, `write`,
    /// etc.) references it as the default argument value — Swift
    /// requires defaulted public arguments to come from publicly-
    /// reachable expressions. External callers don't actually need
    /// to consume the property; the surface exists for the
    /// defaulted-argument indirection.
    public static let homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}