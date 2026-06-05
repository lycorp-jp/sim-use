// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
import Foundation
import SimUseCore
import Testing

@Suite("AppState — result building")
struct AppStateResultTests {

    private func snap(_ pairs: [Int: String]) -> AppSnapshot { AppSnapshot(appsByPid: pairs) }

    @Test("Lists live apps sorted by bundle id; no query when bundle-id absent")
    func listsAppsSorted() {
        let result = AppState.buildResult(
            platform: "ios",
            snapshot: snap([100: "com.x", 50: "a.b"]),
            bundleId: nil,
            didReset: false
        )
        #expect(result.platform == "ios")
        #expect(result.apps == [AppState.AppProcess(bundleId: "a.b", pid: 50),
                                AppState.AppProcess(bundleId: "com.x", pid: 100)])
        #expect(result.query == nil)
        #expect(result.didReset == false)
    }

    @Test("A queried, live bundle reports running")
    func queriedRunning() {
        let result = AppState.buildResult(
            platform: "android",
            snapshot: snap([100: "com.example.app"]),
            bundleId: "com.example.app",
            didReset: false
        )
        #expect(result.query == AppState.AppStateQuery(bundleId: "com.example.app", state: "running"))
    }

    @Test("A queried, absent bundle reports not_running")
    func queriedNotRunning() {
        let result = AppState.buildResult(
            platform: "ios",
            snapshot: snap([:]),
            bundleId: "com.example.app",
            didReset: false
        )
        #expect(result.query == AppState.AppStateQuery(bundleId: "com.example.app", state: "not_running"))
    }

    @Test("didReset flag is propagated")
    func resetFlag() {
        let result = AppState.buildResult(platform: "ios", snapshot: snap([:]), bundleId: nil, didReset: true)
        #expect(result.didReset == true)
    }
}