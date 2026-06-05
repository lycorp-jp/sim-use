// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Process-global `BridgeClient` registry, keyed by adb serial.
///
/// Stateless `sim-use` CLI invocations still pay ~80–150 ms per call on
/// `BridgeSessionStore` disk reads + URLSession setup. Inside the
/// `sim-use daemon` process the same client lives for the lifetime of
/// the daemon: token + forward port + URLSession (with HTTP keep-alive)
/// all stay warm across requests, dropping per-call overhead to the
/// HTTP round-trip alone.
///
/// Thread-safety: `BridgeClient` internals are guarded by an NSLock;
/// `URLSession` is thread-safe; this dictionary is guarded by its own
/// lock. Outside the daemon, calling `.shared(for:)` from a one-shot
/// CLI process is still safe — the registry simply lives only for that
/// process's lifetime and gets re-built next invocation.
public enum BridgeClientRegistry {
    private static let lock = NSLock()
    private static var clients: [String: BridgeClient] = [:]

    /// Return the cached `BridgeClient` for `serial`, creating one on
    /// the first call. The same instance is returned for every
    /// subsequent call within this process.
    ///
    /// The `adb` parameter is only consulted on the **first** call
    /// for a given serial — once an entry exists, subsequent
    /// callers receive the cached instance regardless of what
    /// `adb` they passed. Tests that need to swap in a different
    /// `Adb` configuration must call `invalidate(serial)` first
    /// (or `reset()` to clear the whole table).
    public static func shared(for serial: String, adb: Adb = Adb()) -> BridgeClient {
        lock.lock()
        defer { lock.unlock() }
        if let existing = clients[serial] {
            return existing
        }
        let client = BridgeClient(adb: adb, serial: serial)
        clients[serial] = client
        return client
    }

    /// Drop the cached client for `serial`. The next `shared(for:)` call
    /// will rebuild a fresh one with a freshly bootstrapped
    /// `adb forward` port and auth token.
    ///
    /// Call this when:
    ///   * the daemon detects stale state (bridge process restarted
    ///     on the device, ECONNREFUSED in `sendRaw`).
    ///   * a serial is being recycled: the same emulator-NNNN string
    ///     can map to a different physical device after an emulator
    ///     stop/start, and the cached auth token from the old device
    ///     won't match the new one.
    ///   * a caller wants to switch the `Adb` configuration for an
    ///     already-cached serial (see `shared(for:adb:)`).
    public static func invalidate(_ serial: String) {
        lock.lock()
        defer { lock.unlock() }
        if let client = clients.removeValue(forKey: serial) {
            client.invalidate()
        }
    }

    /// Test-only / shutdown helper.
    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        for client in clients.values {
            client.invalidate()
        }
        clients.removeAll()
    }
}