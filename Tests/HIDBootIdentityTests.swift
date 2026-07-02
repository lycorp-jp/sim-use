// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import Testing

// The HID connection cache is only valid for the boot instance it was
// created against: a simulator shut down and re-booted under the same
// UDID passes the `state == .booted` re-check while the cached mach
// port is dead — and on current SimulatorKit the send against it never
// completes (observed live on Xcode 26.5 / iOS 26.2: the perform hangs,
// so no error ever reaches the failure-classification path).
//
// `HIDBootIdentity` therefore gates cache reuse on a boot token: the
// mtime of `<dataDirectory>/var/run/launchd_bootstrap.plist`, which
// CoreSimulator rewrites on every boot. Pure decision + filesystem
// probe are tested here without FB* types.

@Suite("HIDBootIdentity.isReusable")
struct HIDBootIdentityReusableTests {
    private let bootA = Date(timeIntervalSince1970: 1_782_991_697)
    private let bootB = Date(timeIntervalSince1970: 1_782_995_000)

    @Test("Same token on both sides allows reuse")
    func sameTokenReuses() {
        #expect(HIDBootIdentity.isReusable(cachedToken: bootA, currentToken: bootA))
    }

    @Test("A changed token (reboot) rejects reuse")
    func changedTokenRejects() {
        #expect(!HIDBootIdentity.isReusable(cachedToken: bootA, currentToken: bootB))
    }

    @Test("Unknown tokens reject reuse: rebuilding is cheap, a dead port hangs")
    func unknownTokensReject() {
        // If the marker cannot be read on either side we cannot prove
        // the boot is the same one the connection was created against.
        // Failing closed costs one rebuild (~ms); failing open risks an
        // unrecoverable hang on a dead mach port.
        #expect(!HIDBootIdentity.isReusable(cachedToken: nil, currentToken: bootA))
        #expect(!HIDBootIdentity.isReusable(cachedToken: bootA, currentToken: nil))
        #expect(!HIDBootIdentity.isReusable(cachedToken: nil, currentToken: nil))
    }
}

@Suite("HIDBootIdentity.token")
struct HIDBootIdentityTokenTests {

    private func makeTempDataDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HIDBootIdentityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("var/run"),
            withIntermediateDirectories: true
        )
        return root
    }

    @Test("Token is the boot marker's modification date")
    func tokenReadsMarkerMtime() throws {
        let dataDirectory = try makeTempDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let marker = dataDirectory.appendingPathComponent("var/run/launchd_bootstrap.plist")
        FileManager.default.createFile(atPath: marker.path, contents: Data("boot".utf8))

        let token = HIDBootIdentity.token(dataDirectory: dataDirectory.path)
        let expected = try FileManager.default
            .attributesOfItem(atPath: marker.path)[.modificationDate] as? Date
        #expect(token != nil)
        #expect(token == expected)
    }

    @Test("Rewriting the marker (a new boot) changes the token")
    func rewrittenMarkerChangesToken() throws {
        let dataDirectory = try makeTempDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let marker = dataDirectory.appendingPathComponent("var/run/launchd_bootstrap.plist")
        FileManager.default.createFile(atPath: marker.path, contents: Data("boot-1".utf8))
        let first = HIDBootIdentity.token(dataDirectory: dataDirectory.path)

        // Simulate the next boot rewriting the marker some time later.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: marker.path
        )
        let second = HIDBootIdentity.token(dataDirectory: dataDirectory.path)

        #expect(first != nil)
        #expect(second != nil)
        #expect(first != second)
    }

    @Test("Missing marker file yields nil")
    func missingMarkerIsNil() throws {
        let dataDirectory = try makeTempDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        #expect(HIDBootIdentity.token(dataDirectory: dataDirectory.path) == nil)
    }

    @Test("Nil data directory yields nil")
    func nilDataDirectoryIsNil() {
        #expect(HIDBootIdentity.token(dataDirectory: nil) == nil)
    }
}
