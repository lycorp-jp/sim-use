// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SimUseCore

@Suite("ReleaseVersion.normalize")
struct ReleaseVersionTests {
    @Test("clean release tag with v prefix → stripped form")
    func cleanTagWithPrefix() {
        #expect(ReleaseVersion.normalize("v0.6.0") == "0.6.0")
        #expect(ReleaseVersion.normalize("v1.2.3") == "1.2.3")
        #expect(ReleaseVersion.normalize("v10.20.30") == "10.20.30")
    }

    @Test("clean release tag without v prefix → unchanged")
    func cleanTagWithoutPrefix() {
        #expect(ReleaseVersion.normalize("0.6.0") == "0.6.0")
        #expect(ReleaseVersion.normalize("1.2.3") == "1.2.3")
    }

    @Test("dev / dirty git describe output → nil")
    func devBuilds() {
        // The canonical shape `git describe --tags --dirty` emits
        // between releases — refuse to enforce a version check that
        // would always fail.
        #expect(ReleaseVersion.normalize("v0.5.1-130-ga61c7f1-dirty") == nil)
        #expect(ReleaseVersion.normalize("v0.5.1-130-ga61c7f1") == nil)
        #expect(ReleaseVersion.normalize("v0.5.1-dirty") == nil)
    }

    @Test("non-numeric or partial inputs → nil")
    func malformedInputs() {
        #expect(ReleaseVersion.normalize("dev") == nil)
        #expect(ReleaseVersion.normalize("a61c7f1") == nil)
        #expect(ReleaseVersion.normalize("0.6") == nil)
        #expect(ReleaseVersion.normalize("0.6.") == nil)
        #expect(ReleaseVersion.normalize("0.6.0-rc.1") == nil)
        #expect(ReleaseVersion.normalize("v") == nil)
        #expect(ReleaseVersion.normalize("") == nil)
        #expect(ReleaseVersion.normalize("   ") == nil)
    }

    @Test("whitespace is trimmed before parsing")
    func whitespaceTrimming() {
        #expect(ReleaseVersion.normalize("  v0.6.0\n") == "0.6.0")
    }
}