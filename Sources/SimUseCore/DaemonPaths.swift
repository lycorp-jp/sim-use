// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// Filesystem locations for a per-UDID daemon: its Unix socket, pidfile,
/// and log file. Kept small and side-effect-light so both the client
/// (probing whether a daemon is alive) and the server (creating /
/// cleaning up its own files) can share one canonical layout.
///
/// Path scheme: `/tmp/sim-use-<uid>/<udid>.sock` (plus `.pid` and `.log` peers).
///
/// Why `/tmp` and not `$TMPDIR` — macOS per-user `$TMPDIR` is ~50 chars
/// before we even add our own path segments, so concatenating a 36-char
/// UDID flirts with the 104-char {{sockaddr_un}} path limit. `/tmp` is
/// short, user-specific via the `-<uid>` suffix, and the directory gets
/// mode 0700 so other users cannot see each other's sockets.
public struct DaemonPaths {
    public let udid: String
    public let baseDirectory: URL

    /// Production call-sites use the default `/tmp/sim-use-<uid>/` tree;
    /// tests pass an isolated temporary directory so filesystem
    /// fixtures cannot collide with a real daemon running on the box.
    public init(udid: String, baseDirectory: URL? = nil) {
        self.udid = udid
        self.baseDirectory = baseDirectory ?? Self.defaultBaseDirectory
    }

    public static var defaultBaseDirectory: URL {
        URL(fileURLWithPath: "/tmp/sim-use-\(getuid())", isDirectory: true)
    }

    public var socketURL: URL {
        baseDirectory.appendingPathComponent("\(udid).sock", isDirectory: false)
    }

    public var pidfileURL: URL {
        baseDirectory.appendingPathComponent("\(udid).pid", isDirectory: false)
    }

    public var logfileURL: URL {
        baseDirectory.appendingPathComponent("\(udid).log", isDirectory: false)
    }

    /// Create the base directory with mode 0700 if missing. Idempotent;
    /// safe to call from both the client (before probing) and the server
    /// (before binding) on every invocation.
    ///
    /// `createDirectory` applies the 0700 attribute only on first
    /// creation and silently accepts a pre-existing path. The base
    /// directory lives under world-writable /tmp, so re-validate on
    /// every run: reject symlinks/non-directories and foreign owners
    /// outright (a pre-planted path would let another local user swap
    /// sockets and pidfiles under us), and tighten loose permissions
    /// back to 0700.
    public func ensureBaseDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )

        var st = stat()
        guard lstat(baseDirectory.path, &st) == 0 else {
            throw DaemonSocketError(op: "lstat", errno: errno)
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw DaemonPathsError.insecureBaseDirectory(
                path: baseDirectory.path,
                reason: "it is not a real directory (symlink or special file)"
            )
        }
        guard st.st_uid == getuid() else {
            throw DaemonPathsError.insecureBaseDirectory(
                path: baseDirectory.path,
                reason: "it is owned by uid \(st.st_uid), not the current user (uid \(getuid()))"
            )
        }
        if st.st_mode & 0o077 != 0 {
            guard chmod(baseDirectory.path, 0o700) == 0 else {
                throw DaemonSocketError(op: "chmod", errno: errno)
            }
        }
    }

    /// Read the pid text written by the daemon on startup. Returns nil
    /// if the pidfile does not exist or does not parse.
    public func readPidfile() -> pid_t? {
        guard let data = try? Data(contentsOf: pidfileURL),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func writePidfile(_ pid: pid_t) throws {
        let data = Data("\(pid)\n".utf8)
        try data.write(to: pidfileURL, options: .atomic)
    }

    public func removeSocket() {
        try? FileManager.default.removeItem(at: socketURL)
    }

    public func removePidfile() {
        try? FileManager.default.removeItem(at: pidfileURL)
    }

    /// `kill(pid, 0)` returns 0 when the process exists and we have
    /// permission to signal it. Any negative return means the pid is
    /// dead, reused by another user, or otherwise unusable.
    public static func isProcessAlive(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return Darwin.kill(pid, 0) == 0
    }

    /// Best-effort stale-state probe. The client calls this before
    /// deciding whether to auto-start a new daemon. Rules:
    ///
    /// * No socket file at all → no daemon, client must spawn one.
    /// * Socket exists, pidfile missing or unparseable → stale; unlink
    ///   socket and treat as "no daemon".
    /// * Socket + pidfile present, PID alive → daemon is presumed
    ///   running; a ping confirms liveness definitively (done elsewhere
    ///   once the transport layer exists).
    /// * Socket + pidfile present, PID dead → stale; unlink both and
    ///   treat as "no daemon".
    public func filesystemLiveness() -> FilesystemLiveness {
        let fm = FileManager.default
        guard fm.fileExists(atPath: socketURL.path) else {
            return .noDaemon
        }
        guard let pid = readPidfile() else {
            removeSocket()
            return .noDaemon
        }
        guard Self.isProcessAlive(pid: pid) else {
            removeSocket()
            removePidfile()
            return .noDaemon
        }
        return .probablyAlive(pid: pid)
    }

    public enum FilesystemLiveness {
        case noDaemon
        case probablyAlive(pid: pid_t)
    }

    public enum DaemonPathsError: Error, CustomStringConvertible, LocalizedError {
        case insecureBaseDirectory(path: String, reason: String)

        public var description: String {
            switch self {
            case .insecureBaseDirectory(let path, let reason):
                return "Daemon base directory \(path) is not safe to use: \(reason). Remove it and retry."
            }
        }

        public var errorDescription: String? { description }
    }

    /// A daemon discovered during a directory scan: its UDID, live pid,
    /// and a `DaemonPaths` handle for socket/pidfile/log access.
    public struct DiscoveredDaemon {
        public let udid: String
        public let pid: pid_t
        public let paths: DaemonPaths

        public init(udid: String, pid: pid_t, paths: DaemonPaths) {
            self.udid = udid
            self.pid = pid
            self.paths = paths
        }
    }

    /// Enumerate every daemon under the base directory whose pidfile
    /// parses and whose pid is still alive. Stale pidfiles whose owners
    /// are dead are cleaned as a side effect (matching
    /// `filesystemLiveness`'s existing behaviour), so callers only see
    /// daemons that are at least probably reachable. `baseDirectory`
    /// defaults to `/tmp/sim-use-<uid>/`; tests pass an isolated directory.
    public static func enumerateLiveDaemons(baseDirectory: URL? = nil) -> [DiscoveredDaemon] {
        let baseDir = baseDirectory ?? Self.defaultBaseDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var discovered: [DiscoveredDaemon] = []
        for entry in entries where entry.pathExtension == "pid" {
            let udid = entry.deletingPathExtension().lastPathComponent
            let paths = DaemonPaths(udid: udid, baseDirectory: baseDir)
            if case .probablyAlive(let pid) = paths.filesystemLiveness() {
                discovered.append(DiscoveredDaemon(udid: udid, pid: pid, paths: paths))
            }
        }
        return discovered.sorted { $0.udid < $1.udid }
    }
}