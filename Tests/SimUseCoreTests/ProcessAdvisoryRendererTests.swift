// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import Foundation
import Testing

@Suite("ProcessAdvisoryRenderer — outline banners")
struct ProcessAdvisoryRendererTests {

    private func event(_ kind: ProcessEventKind, _ confidence: ProcessEventConfidence, pid: Int? = 64726) -> ProcessEvent {
        ProcessEvent(kind: kind, bundleId: "com.example.app", pid: pid, confidence: confidence)
    }

    @Test("A high-confidence disappearance renders a loud banner with bundle id and pid")
    func loudDisappeared() {
        let advisory = ProcessAdvisory(events: [event(.disappeared, .high)], pending: [event(.disappeared, .high)])
        let banner = ProcessAdvisoryRenderer.banner(for: advisory)
        let text = try! #require(banner)
        #expect(text.contains("PROCESS DISAPPEARED"))
        #expect(text.contains("com.example.app"))
        #expect(text.contains("64726"))
        #expect(text.contains("===="))   // loud rule lines
    }

    @Test("A replaced (crash-and-relaunch) event reads as relaunched")
    func loudReplaced() {
        let advisory = ProcessAdvisory(events: [event(.replaced, .high)], pending: [])
        let text = try! #require(ProcessAdvisoryRenderer.banner(for: advisory))
        #expect(text.contains("com.example.app"))
        #expect(text.lowercased().contains("relaunch"))
    }

    @Test("A low-confidence idle change is a quiet single line, not the loud banner")
    func quietIdleChange() {
        let advisory = ProcessAdvisory(events: [event(.changedWhileIdle, .low)], pending: [])
        let text = try! #require(ProcessAdvisoryRenderer.banner(for: advisory))
        #expect(text.contains("com.example.app"))
        #expect(!text.contains("===="))                 // never loud
        #expect(text.contains("[i]"))                    // quiet marker
    }

    @Test("Pending-only (no new event) renders the level sticky note")
    func levelStickyNote() {
        let advisory = ProcessAdvisory(events: [], pending: [event(.disappeared, .high)])
        let text = try! #require(ProcessAdvisoryRenderer.banner(for: advisory))
        #expect(text.contains("[!]"))
        #expect(text.contains("com.example.app"))
        #expect(!text.contains("===="))                 // condensed, not loud
    }

    @Test("An empty advisory renders nothing")
    func emptyAdvisory() {
        #expect(ProcessAdvisoryRenderer.banner(for: ProcessAdvisory(events: [], pending: [])) == nil)
    }
}