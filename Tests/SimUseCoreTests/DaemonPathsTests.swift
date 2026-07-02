// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import Darwin
import Foundation
import Testing

// MARK: - Fixtures

private func makeTempDirectory(file: StaticString = #file, line: UInt = #line) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sim-use-daemon-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func removeTempDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private func writeFile(_ url: URL, _ text: String = "") throws {
    try Data(text.utf8).write(to: url)
}

// A pid that is implausible to be alive on any stock macOS host
// (pid_max caps well below this). Used to drive the "dead pid"
// branch of filesystemLiveness without spawning a throwaway child.
private let implausiblePid: pid_t = 9_999_997

// MARK: - URL construction

@Suite("DaemonPaths URL construction")
struct DaemonPathsURLTests {
    @Test("socket / pid / log URLs live under the base directory, keyed by UDID")
    func urlComposition() {
        let base = URL(fileURLWithPath: "/var/folders/sim-use-test", isDirectory: true)
        let paths = DaemonPaths(udid: "ABC-123", baseDirectory: base)

        #expect(paths.socketURL.path == "/var/folders/sim-use-test/ABC-123.sock")
        #expect(paths.pidfileURL.path == "/var/folders/sim-use-test/ABC-123.pid")
        #expect(paths.logfileURL.path == "/var/folders/sim-use-test/ABC-123.log")
    }

    @Test("Default base directory is /tmp/sim-use-<uid>")
    func defaultBaseDirectory() {
        let paths = DaemonPaths(udid: "ABC")
        #expect(paths.baseDirectory.path == "/tmp/sim-use-\(getuid())")
    }
}

// MARK: - Pidfile I/O

@Suite("DaemonPaths pidfile I/O")
struct DaemonPathsPidfileTests {
    @Test("writePidfile + readPidfile round-trip")
    func writeRead() throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let paths = DaemonPaths(udid: "U", baseDirectory: tmp)
        try paths.writePidfile(42)
        #expect(paths.readPidfile() == 42)
    }

    @Test("readPidfile returns nil when file is missing")
    func readMissing() throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let paths = DaemonPaths(udid: "U", baseDirectory: tmp)
        #expect(paths.readPidfile() == nil)
    }

    @Test("readPidfile returns nil when file contents do not parse as a pid")
    func readUnparseable() throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let paths = DaemonPaths(udid: "U", baseDirectory: tmp)
        try writeFile(paths.pidfileURL, "not-a-pid")
        #expect(paths.readPidfile() == nil)
    }

    @Test("readPidfile trims surrounding whitespace")
    func readTrimmed() throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let paths = DaemonPaths(udid: "U", baseDirectory: tmp)
        try writeFile(paths.pidfileURL, "  1234\n")
        #expect(paths.readPidfile() == 1234)
    }
}

// MARK: - isProcessAlive

@Suite("DaemonPaths.isProcessAlive")
struct DaemonPathsIsAliveTests {
    @Test("pid == 0 is never considered alive")
    func zero() {
        #expect(DaemonPaths.isProcessAlive(pid: 0) == false)
    }

    @Test("Current process pid is alive")
    func selfPid() {
        #expect(DaemonPaths.isProcessAlive(pid: getpid()))
    }

    @Test("Implausibly-high pid is reported dead")
    func deadPid() {
        #expect(DaemonPaths.isProcessAlive(pid: implausiblePid) == false)
    }
}

// MARK: - filesystemLiveness

@Suite("DaemonPaths.filesystemLiveness")
struct DaemonPathsLivenessTests {
    @Test("noDaemon when socket is absent")
    func noSocket() throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let paths = DaemonPaths(udid: "U", baseDirectory: tmp)

        if case .noDaemon = paths.filesystemLiveness() {
        } else {
            Issue.record("expected .noDaemon when no files exist")
        }
    }

    @Test("Socket without pidfile is stale: noDaemon + socket cleaned")
    func socketOnly() throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let paths = DaemonPaths(udid: "U", baseDirectory: tmp)
        try writeFile(paths.socketURL)

        if case .noDaemon = paths.filesystemLiveness() {
        } else {
            Issue.record("expected .noDaemon when pidfile missing")
        }
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
    }

    @Test("Socket + dead pid is stale: noDaemon + both files cleaned")
    func deadPid() throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let paths = DaemonPaths(udid: "U", baseDirectory: tmp)
        try writeFile(paths.socketURL)
        try writeFile(paths.pidfileURL, "\(implausiblePid)\n")

        if case .noDaemon = paths.filesystemLiveness() {
        } else {
            Issue.record("expected .noDaemon when pid is dead")
        }
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
        #expect(!FileManager.default.fileExists(atPath: paths.pidfileURL.path))
    }

    @Test("Socket + live (self) pid is probablyAlive; files are not touched")
    func alivePid() throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let paths = DaemonPaths(udid: "U", baseDirectory: tmp)
        try writeFile(paths.socketURL)
        try writeFile(paths.pidfileURL, "\(getpid())\n")

        guard case .probablyAlive(let pid) = paths.filesystemLiveness() else {
            Issue.record("expected .probablyAlive when pid is self")
            return
        }
        #expect(pid == getpid())
        #expect(FileManager.default.fileExists(atPath: paths.socketURL.path))
        #expect(FileManager.default.fileExists(atPath: paths.pidfileURL.path))
    }
}

// MARK: - enumerateLiveDaemons

@Suite("DaemonPaths.enumerateLiveDaemons")
struct DaemonPathsEnumerateTests {
    @Test("Empty directory returns no discovered daemons")
    func emptyDirectory() throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        #expect(DaemonPaths.enumerateLiveDaemons(baseDirectory: tmp).isEmpty)
    }

    @Test("Missing directory returns no discovered daemons")
    func missingDirectory() {
        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-daemon-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(DaemonPaths.enumerateLiveDaemons(baseDirectory: ghost).isEmpty)
    }

    @Test("Non-.pid files are ignored")
    func ignoresOtherExtensions() throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        try writeFile(tmp.appendingPathComponent("something.log"), "noise")
        try writeFile(tmp.appendingPathComponent("another.txt"), "noise")
        try writeFile(tmp.appendingPathComponent("bare"), "noise")

        #expect(DaemonPaths.enumerateLiveDaemons(baseDirectory: tmp).isEmpty)
    }

    @Test("Live and dead daemons: dead is skipped and cleaned, live is returned")
    func mixedAliveAndDead() throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let alive = DaemonPaths(udid: "B-alive", baseDirectory: tmp)
        try writeFile(alive.socketURL)
        try writeFile(alive.pidfileURL, "\(getpid())\n")

        let dead = DaemonPaths(udid: "A-dead", baseDirectory: tmp)
        try writeFile(dead.socketURL)
        try writeFile(dead.pidfileURL, "\(implausiblePid)\n")

        let discovered = DaemonPaths.enumerateLiveDaemons(baseDirectory: tmp)
        #expect(discovered.count == 1)
        #expect(discovered.first?.udid == "B-alive")
        #expect(discovered.first?.pid == getpid())

        #expect(!FileManager.default.fileExists(atPath: dead.socketURL.path))
        #expect(!FileManager.default.fileExists(atPath: dead.pidfileURL.path))
    }

    @Test("Discovered daemons are sorted by UDID")
    func sortedByUDID() throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        for udid in ["ZZZ", "AAA", "MMM"] {
            let paths = DaemonPaths(udid: udid, baseDirectory: tmp)
            try writeFile(paths.socketURL)
            try writeFile(paths.pidfileURL, "\(getpid())\n")
        }

        let discovered = DaemonPaths.enumerateLiveDaemons(baseDirectory: tmp)
        #expect(discovered.map(\.udid) == ["AAA", "MMM", "ZZZ"])
    }
}
// MARK: - Base directory hardening

// The base directory lives under world-writable /tmp, so its 0700 mode
// is only meaningful if we verify it on every run: `createDirectory`
// applies the permission attribute solely on first creation and
// silently accepts a pre-existing directory — including one another
// local user pre-created (with their ownership and mode) to swap
// sockets/pidfiles under us, or a symlink planted at the path.
@Suite("DaemonPaths.ensureBaseDirectory hardening")
struct DaemonPathsEnsureBaseDirectoryTests {
    private func mode(of url: URL) throws -> mode_t {
        var st = stat()
        try #require(lstat(url.path, &st) == 0)
        return st.st_mode & 0o777
    }

    @Test("Fresh creation applies mode 0700")
    func freshCreationIs0700() throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let base = tmp.appendingPathComponent("fresh-base", isDirectory: true)
        let paths = DaemonPaths(udid: "U", baseDirectory: base)
        try paths.ensureBaseDirectory()
        #expect(try mode(of: base) == 0o700)
    }

    @Test("Pre-existing directory with loose permissions is tightened to 0700")
    func looseExistingDirectoryIsTightened() throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let base = tmp.appendingPathComponent("loose-base", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try #require(chmod(base.path, 0o777) == 0)

        let paths = DaemonPaths(udid: "U", baseDirectory: base)
        try paths.ensureBaseDirectory()
        #expect(try mode(of: base) == 0o700)
    }

    @Test("A symlink planted at the base path is rejected")
    func symlinkAtBasePathThrows() throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let target = tmp.appendingPathComponent("real-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let base = tmp.appendingPathComponent("link-base", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: base, withDestinationURL: target)

        let paths = DaemonPaths(udid: "U", baseDirectory: base)
        #expect(throws: (any Error).self) {
            try paths.ensureBaseDirectory()
        }
    }
}
