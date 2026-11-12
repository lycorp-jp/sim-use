// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Persistent per-UDID bridge connection state. Lets the stateless CLI
/// reuse an `adb forward` registration across invocations, and for a short
/// time the endpoint and token that the last provider discovery returned.
/// The file is also the record of the one forward that sim-use processes
/// share for this device.
///
/// File layout: `~/.sim-use/<udid>/bridge.json`. Best-effort — if the
/// file is unreadable, was written under another `BridgeConnection`
/// (or before sessions recorded one), or its forward is no longer
/// listed by `adb forward --list`, the BridgeClient falls back to a cold
/// bootstrap (provider discovery + `adb forward`) and rewrites the
/// cache on success. A session outside
/// `BridgeClient.restoredSessionTrustWindow` keeps its forward but needs
/// discovery again. A running daemon keeps its validated session in memory
/// and does not query adb again until failure.
public struct BridgeSession: Codable, Equatable, Sendable {
    public let token: String
    public let localPort: Int
    public let remotePort: Int
    /// `BridgeConnection.identity` the forward and token were created
    /// under. Nil in caches written before sessions recorded it.
    public let connection: String?
    /// Canonical adb server owning the forward; nil in older caches.
    public let adbServer: String?
    /// When the shell-only provider returned this endpoint and token. Nil in
    /// caches from releases that connected without discovery.
    public let discoveredAt: Date?
    public let writtenAt: Date

    public init(
        token: String, localPort: Int, remotePort: Int,
        connection: String? = nil, adbServer: String? = nil,
        discoveredAt: Date? = nil, writtenAt: Date = Date()
    ) {
        self.token = token
        self.localPort = localPort
        self.remotePort = remotePort
        self.connection = connection
        self.adbServer = adbServer
        self.discoveredAt = discoveredAt
        self.writtenAt = writtenAt
    }
}

public enum BridgeSessionStore {

    /// Coordinate the complete disk/forward transition, not just a file write.
    /// Keep this file in place so all waiters continue to lock the same inode.
    static func withExclusiveAccess<Result>(
        udid: String, home: URL = homeDirectory, timeout: TimeInterval = 30,
        _ body: () throws -> Result
    ) throws -> Result {
        guard isValidUDID(udid) else {
            throw BridgeError.transport(underlying: "Invalid bridge session device serial", serial: udid)
        }
        let dir = directory(for: udid, home: home)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let fd = open(dir.appendingPathComponent("bridge.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw BridgeError.transport(underlying: "Could not open the shared bridge session lock", serial: udid)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_nlink == 1 else {
            throw BridgeError.transport(underlying: "The bridge session lock is not a private regular file", serial: udid)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw BridgeError.transport(underlying: "Could not acquire the shared bridge session lock", serial: udid)
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw BridgeError.transport(underlying: "Timed out waiting for another bridge session transition", serial: udid)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return try body()
    }

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
