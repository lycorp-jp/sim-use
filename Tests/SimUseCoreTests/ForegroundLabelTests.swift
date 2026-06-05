// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import Foundation
import Testing

@Suite("ForegroundLabel — header reconciliation")
struct ForegroundLabelTests {

    // MARK: - systemShellName

    @Test("Maps SpringBoard bundle id to a friendly name")
    func mapsSpringBoard() {
        #expect(ForegroundLabel.systemShellName(forBundleId: "com.apple.springboard") == "SpringBoard")
    }

    @Test("Returns nil for a real app bundle id")
    func realAppIsNotShell() {
        #expect(ForegroundLabel.systemShellName(forBundleId: "com.example.app") == nil)
    }

    @Test("Returns nil for nil / empty bundle id")
    func emptyBundleIsNotShell() {
        #expect(ForegroundLabel.systemShellName(forBundleId: nil) == nil)
        #expect(ForegroundLabel.systemShellName(forBundleId: "") == nil)
    }

    // MARK: - reconcile

    @Test("A resolved system-shell bundle overrides a stale AX label")
    func systemShellOverridesStaleLabel() {
        // The crash→SpringBoard transition leaves the AX root carrying
        // the dying app's label; the resolved foreground bundle is the
        // source of truth.
        let label = ForegroundLabel.reconcile(
            axRootLabel: "LINE Dev",
            foregroundBundleId: "com.apple.springboard",
            fallback: "App"
        )
        #expect(label == "SpringBoard")
    }

    @Test("An empty AX label resolves to the system-shell name, not blank")
    func emptyLabelResolvesToShell() {
        let label = ForegroundLabel.reconcile(
            axRootLabel: "",
            foregroundBundleId: "com.apple.springboard",
            fallback: "App"
        )
        #expect(label == "SpringBoard")
    }

    @Test("A real app keeps its AX label when bundle agrees")
    func realAppKeepsLabel() {
        let label = ForegroundLabel.reconcile(
            axRootLabel: "LINE",
            foregroundBundleId: "com.example.app",
            fallback: "App"
        )
        #expect(label == "LINE")
    }

    @Test("An empty label with a real bundle falls back to the bundle id, never blank")
    func emptyLabelFallsBackToBundleId() {
        let label = ForegroundLabel.reconcile(
            axRootLabel: "",
            foregroundBundleId: "com.example.app",
            fallback: "App"
        )
        #expect(label == "com.example.app")
    }

    @Test("No label and no bundle uses the caller's fallback")
    func noSignalUsesFallback() {
        #expect(ForegroundLabel.reconcile(axRootLabel: "", foregroundBundleId: "", fallback: "App") == "App")
        #expect(ForegroundLabel.reconcile(axRootLabel: nil, foregroundBundleId: nil, fallback: "App") == "App")
    }
}