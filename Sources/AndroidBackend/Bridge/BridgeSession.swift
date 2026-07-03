// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Persistent per-UDID bridge connection state. Lets the stateless CLI
/// reuse the bearer token and the `adb forward` port across
/// invocations instead of paying `adb shell content query` (~1s) +
/// `adb forward` (~50ms) every call.
///
/// File layout: `~/.sim-use/<udid>/bridge.json`. Best-effort — if the
/// file is unreadable or the cached forward is dead, the BridgeClient
/// falls back to a cold bootstrap (`AuthTokenFetcher.fetch` + `adb
/// forward`) and rewrites the cache on success.
///
/// This is a stopgap for V1 while a proper Android daemon (C11) is
/// pending. The daemon will subsume this when it lands.
public struct BridgeSession: Codable, Equatable, Sendable {
    public let token: String
    public let localPort: Int
    public let remotePort: Int
    public let writtenAt: Date

    public init(token: String, localPort: Int, remotePort: Int, writtenAt: Date = Date()) {
        self.token = token
        self.localPort = localPort
        self.remotePort = remotePort
        self.writtenAt = writtenAt
    }
}

public enum BridgeSessionStore {

    public static func directory(for udid: String, home: URL = homeDirectory) -> URL {
        home
            .appendingPathComponent(".sim-use", isDirectory: true)
            .appendingPathComponent(udid, isDirectory: true)
    }

    public static func file(for udid: String, home: URL = homeDirectory) -> URL {
        directory(for: udid, home: home).appendingPathComponent("bridge.json")
    }

    public static func read(udid: String, home: URL = homeDirectory) -> BridgeSession? {
        guard isValidUDID(udid) else { return nil }
        let url = file(for: udid, home: home)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BridgeSession.self, from: data)
    }

    public static func write(_ session: BridgeSession, udid: String, home: URL = homeDirectory) {
        guard isValidUDID(udid) else { return }
        let dir = directory(for: udid, home: home)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(session) else { return }
        let url = file(for: udid, home: home)
        try? data.write(to: url, options: [.atomic])
        // Default `Data.write` inherits the process umask (typically
        // 0o644 = world-readable). This file holds the bearer token
        // used to talk to the on-device HTTP bridge; restrict to
        // owner read/write only. The directory is already 0o700, so
        // other users on the host couldn't list the path, but
        // `chmod` discipline at the file level matters for shared
        // backup tools, leaked-tarballs scenarios, and any future
        // path that hands the directory out under broader perms.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    public static func invalidate(udid: String, home: URL = homeDirectory) {
        guard isValidUDID(udid) else { return }
        try? FileManager.default.removeItem(at: file(for: udid, home: home))
    }

    /// Rejects udids that would escape the `~/.sim-use/` tree
    /// (`..`, slash-containing, empty) or that aren't well-formed adb
    /// serials. `adb devices` always emits well-formed serials in
    /// practice, so this is a defence-in-depth guard rather than a
    /// regularly-triggered filter.
    static func isValidUDID(_ udid: String) -> Bool {
        if udid.isEmpty { return false }
        if udid == "." || udid == ".." { return false }
        if udid.contains("/") { return false }
        // Allow only characters that appear in real adb serials:
        // hex / dashes (emulator-NNNN, RFFNW00H4WK), dots and colons
        // (Wi-Fi adb: 192.168.1.5:5555), and underscores
        // (occasionally produced by emulator tooling).
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-"
        )
        return udid.unicodeScalars.allSatisfy(allowed.contains)
    }

    public static let homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
}