// SPDX-License-Identifier: Apache-2.0
import FBSimulatorControl
import Foundation
@testable import iOSSimBackend
import SimUseCore
import Testing

// The frontmost-tree fetch replaces idb's point-oriented
// `noTranslationObject` text with one that names the stale
// CoreSimulatorBridge and how to restart it.

@Suite("FrontmostAccessibilityError")
struct FrontmostAccessibilityErrorTests {
    @Test("noTranslationObject maps to the frontmost error for that simulator")
    func mapsNoTranslationObject() {
        let mapped = FrontmostAccessibilityError.mapping(FBAccessibilityError.noTranslationObject, udid: "UDID-1")
        #expect(mapped as? FrontmostAccessibilityError == FrontmostAccessibilityError(udid: "UDID-1"))
    }

    @Test("other errors pass through unchanged")
    func passesOtherErrorsThrough() {
        let mapped = FrontmostAccessibilityError.mapping(FBAccessibilityError.springBoardNotRunning, udid: "UDID-1")
        #expect(mapped as? FrontmostAccessibilityError == nil)
        #expect(mapped.localizedDescription == FBAccessibilityError.springBoardNotRunning.localizedDescription)
    }

    @Test("the description still classifies as transient so a fresh boot gets its retry")
    func keepsTransientClassification() {
        let error = FrontmostAccessibilityError(udid: "UDID-1")
        #expect(DaemonErrorKind.classify(error) == .transientBooting)
        #expect(!error.localizedDescription.contains("fullscreen dialog"))
    }

    @Test("the hint gives the bridge restart command for that simulator")
    func hintNamesBridgeRestart() throws {
        let hint = try #require(FrontmostAccessibilityError(udid: "UDID-1").hint)
        #expect(hint.contains("xcrun simctl spawn UDID-1 launchctl stop com.apple.CoreSimulator.bridge"))
        #expect(hint.contains("wait a few seconds and retry"))
    }
}
