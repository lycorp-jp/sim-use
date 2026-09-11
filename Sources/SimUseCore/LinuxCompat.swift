// SPDX-License-Identifier: Apache-2.0
//
// Linux shims for the two Apple-only surfaces SimUseCore reaches for in
// otherwise portable code. Everything here is compiled out on Apple
// platforms and is `internal`, so no other module can see it.

#if !canImport(Darwin) && canImport(Glibc)
import Glibc

/// The daemon layer qualifies its POSIX calls (`Darwin.close(fd)`) so
/// they cannot be shadowed by same-named Swift members. Glibc exports
/// the same symbols; this namespace forwards to them so those call
/// sites compile on Linux without an `#if` at each one.
enum Darwin {
    @discardableResult static func close(_ fd: Int32) -> Int32 { Glibc.close(fd) }

    @discardableResult static func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer!, _ count: Int) -> Int {
        Glibc.read(fd, buf, count)
    }

    @discardableResult static func write(_ fd: Int32, _ buf: UnsafeRawPointer!, _ count: Int) -> Int {
        Glibc.write(fd, buf, count)
    }

    // Glibc types SOCK_STREAM as `__socket_type`, Darwin as Int32.
    @discardableResult static func socket(_ domain: Int32, _ type: __socket_type, _ proto: Int32) -> Int32 {
        Glibc.socket(domain, Int32(type.rawValue), proto)
    }

    @discardableResult static func bind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>!, _ len: socklen_t) -> Int32 {
        Glibc.bind(fd, addr, len)
    }

    @discardableResult static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 {
        Glibc.listen(fd, backlog)
    }

    @discardableResult static func connect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>!, _ len: socklen_t) -> Int32 {
        Glibc.connect(fd, addr, len)
    }

    @discardableResult static func accept(
        _ fd: Int32,
        _ addr: UnsafeMutablePointer<sockaddr>!,
        _ len: UnsafeMutablePointer<socklen_t>!
    ) -> Int32 {
        Glibc.accept(fd, addr, len)
    }

    @discardableResult static func kill(_ pid: pid_t, _ signal: Int32) -> Int32 {
        Glibc.kill(pid, signal)
    }

    static func exit(_ code: Int32) -> Never { Glibc.exit(code) }
}
#endif

#if !canImport(os)
import Foundation

/// Stand-in for `os.OSAllocatedUnfairLock`, which `ProcessControl` uses
/// as a cheap synchronous mutex around a value. Only the
/// `init(initialState:)` / `withLock` surface it needs is provided;
/// `NSLock` likewise avoids an actor hop per check.
final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(initialState: State) {
        self.state = initialState
    }

    @discardableResult
    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
#endif
