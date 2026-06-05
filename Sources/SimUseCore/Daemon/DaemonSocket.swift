// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// Thin wrappers around `socket(2)` / `bind(2)` / `connect(2)` for Unix
/// domain stream sockets. Network.framework's support for Unix domain
/// listeners is awkward enough that dropping to BSD sockets is shorter
/// and easier to reason about for our "one connection per request,
/// line-delimited JSON" protocol.
///
/// All functions here throw `DaemonSocketError` on syscall failure so
/// higher layers can surface `strerror(errno)` verbatim to the user.
public enum DaemonSocket {
    /// Create a listening Unix domain stream socket bound to `path`.
    /// Unlinks any stale file at the path first. The returned fd is
    /// owned by the caller and must be `close`d.
    public static func listen(path: String, backlog: Int32 = 16) throws -> Int32 {
        try ensurePathFits(path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw DaemonSocketError(op: "socket", errno: errno) }

        // Pre-emptively remove any stale socket file at the target path.
        // Bind fails with EADDRINUSE otherwise even if the previous owner
        // is long gone.
        unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        copyPath(path, into: &addr)

        let bindResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindResult < 0 {
            let err = errno
            close(fd)
            throw DaemonSocketError(op: "bind", errno: err)
        }

        // Restrict socket to the owning user only. mode 0600 matches the
        // enclosing /tmp/sim-use-<uid>/ 0700 and blocks cross-user snooping
        // on multi-user machines.
        chmod(path, 0o600)

        if Darwin.listen(fd, backlog) < 0 {
            let err = errno
            close(fd)
            unlink(path)
            throw DaemonSocketError(op: "listen", errno: err)
        }

        // Non-blocking listener. The DispatchSource-driven accept loop
        // drains pending connections and relies on `accept()` returning
        // EAGAIN / EWOULDBLOCK when the queue is empty. A blocking
        // listener combined with the coalescing / multi-fire behaviour
        // of DispatchSource can deadlock the main actor: a spurious
        // fire leads to accept() blocking on an empty queue, freezing
        // every queued MainActor task behind it.
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        return fd
    }

    /// Client-side connect. Returns a connected fd or throws.
    public static func connect(path: String, timeout: TimeInterval = 0.25) throws -> Int32 {
        try ensurePathFits(path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw DaemonSocketError(op: "socket", errno: errno) }

        // Connect with a short timeout so a half-dead socket (file exists
        // but no listener) fails fast instead of hanging the client.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        copyPath(path, into: &addr)

        let connectResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult == 0 {
            _ = fcntl(fd, F_SETFL, flags)
            return fd
        }

        if errno != EINPROGRESS {
            let err = errno
            close(fd)
            throw DaemonSocketError(op: "connect", errno: err)
        }

        // Wait for writability within the timeout.
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let timeoutMs = Int32(timeout * 1000)
        let pollResult = poll(&pfd, 1, timeoutMs)
        if pollResult <= 0 {
            let err = pollResult == 0 ? ETIMEDOUT : errno
            close(fd)
            throw DaemonSocketError(op: "poll/connect", errno: err)
        }

        // Check the final connect status via SO_ERROR.
        var soError: Int32 = 0
        var soLen: socklen_t = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLen)
        if soError != 0 {
            close(fd)
            throw DaemonSocketError(op: "connect", errno: soError)
        }

        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    /// Blocking read up to and including a `\n` (consumed but not
    /// returned). Returns nil on EOF before any bytes. `limit` caps the
    /// buffer so a malformed peer can't OOM the daemon.
    ///
    /// Reads in 8 KB chunks: byte-by-byte reads were catastrophic for
    /// the ~17 KB describe-ui response (one read syscall per byte ~
    /// hundreds of ms of client overhead). Our wire is strict
    /// one-request-per-connection, so discarding anything past the
    /// first `\n` is safe.
    public static func readLine(fd: Int32, limit: Int = 8 * 1024 * 1024) -> Data? {
        var buf = Data()
        buf.reserveCapacity(4096)
        var chunk = [UInt8](repeating: 0, count: 8192)
        while buf.count < limit {
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if n == 0 {
                return buf.isEmpty ? nil : buf
            }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if let newlineIndex = chunk.prefix(n).firstIndex(of: 0x0A) {
                buf.append(contentsOf: chunk[0..<newlineIndex])
                return buf
            }
            buf.append(contentsOf: chunk[0..<n])
        }
        return buf
    }

    /// Blocking write of the entire buffer. Returns (success, lastErrno).
    /// On success the errno component is 0; on failure it carries the
    /// syscall errno so callers can log / classify without a second
    /// round-trip through `strerror`.
    @discardableResult
    public static func writeAll(fd: Int32, data: Data) -> (ok: Bool, lastErrno: Int32) {
        data.withUnsafeBytes { raw -> (Bool, Int32) in
            guard let base = raw.baseAddress else { return (true, 0) }
            var remaining = raw.count
            var offset = 0
            while remaining > 0 {
                let n = Darwin.write(fd, base.advanced(by: offset), remaining)
                if n < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    return (false, err)
                }
                offset += n
                remaining -= n
            }
            return (true, 0)
        }
    }

    // MARK: - Internals

    private static func ensurePathFits(_ path: String) throws {
        let sunPathCapacity = MemoryLayout<sockaddr_un>.size - MemoryLayout<UInt8>.size - MemoryLayout<sa_family_t>.size
        if path.utf8.count >= sunPathCapacity {
            throw DaemonSocketError.pathTooLong(path: path, limit: sunPathCapacity)
        }
    }

    private static func copyPath(_ path: String, into addr: inout sockaddr_un) {
        // `sun_path` is a C array; Swift exposes it as a tuple. Memcpy
        // bytes into the tuple's storage via withUnsafeMutablePointer +
        // memory-rebinding, followed by a NUL terminator. Capacity is
        // captured before we borrow `sun_path` to avoid Swift's
        // exclusive-access violation on `addr.sun_path` inside the
        // `withUnsafeMutablePointer` block.
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
                tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { bytes in
                    let count = strlen(src)
                    memcpy(bytes, src, count)
                    bytes[count] = 0
                }
            }
        }
    }
}

public enum DaemonSocketError: Error, CustomStringConvertible {
    case syscallFailed(op: String, errno: Int32, message: String)
    case pathTooLong(path: String, limit: Int)

    public init(op: String, errno: Int32) {
        let msg = String(cString: strerror(errno))
        self = .syscallFailed(op: op, errno: errno, message: msg)
    }

    public var description: String {
        switch self {
        case .syscallFailed(let op, let errno, let message):
            return "Daemon socket \(op) failed (errno=\(errno)): \(message)"
        case .pathTooLong(let path, let limit):
            return "Socket path is \(path.utf8.count) bytes but the AF_UNIX limit is \(limit): \(path)"
        }
    }
}