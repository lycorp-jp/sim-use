// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend

final class BridgeClientSendableTests: XCTestCase {

    /// `BridgeClient` is handed out by `BridgeClientRegistry.shared(for:)`
    /// to concurrent callers across daemon worker threads. The class
    /// owns mutable cached state (`cachedLocalPort`, `cachedAuthToken`,
    /// `cachedDisplay`, `verifiedProtocolVersion`) and protects it with
    /// `NSLock`. The Sendable conformance is therefore `@unchecked`,
    /// not synthesized — but it must exist so the compiler stops
    /// warning on every cross-actor send the daemon performs.
    ///
    /// This test is a compile-time assertion: `requireSendable` only
    /// type-checks when the argument's type carries a `Sendable`
    /// conformance. If a future refactor removes the conformance the
    /// test file fails to build, blocking the regression at compile
    /// time rather than silently surfacing as a Swift-6 strict-
    /// concurrency diagnostic in callers.
    func testBridgeClientIsSendable() {
        requireSendable(BridgeClient.self)
    }
}

private func requireSendable<T: Sendable>(_ type: T.Type) { _ = type }