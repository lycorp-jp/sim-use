// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Suite("Android Button Tests", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidButtonTests {
    @Test("Back key increments the intercepted counter")
    func backIncrementsCount() async throws {
        try await AndroidE2E.launch(screen: "button-test")

        try await AndroidE2E.run("button back")
        try await Task.sleep(nanoseconds: 800_000_000)
        try await AndroidE2E.run("button back")

        let ui = try await AndroidE2E.waitForOutline {
            AndroidE2E.trailingInt($0.label(resourceId: "back_press_count")) == 2
        }
        #expect(AndroidE2E.trailingInt(ui.label(resourceId: "back_press_count")) == 2)
    }

    @Test("Home backgrounds the app; it stays alive and relaunches")
    func homeThenRelaunch() async throws {
        try await AndroidE2E.launch(screen: "button-test")

        try await AndroidE2E.run("button home")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let running = try await AndroidE2E.runningPackages()
        #expect(running.contains(AndroidE2E.playgroundPackage), "playground should stay alive after home")

        try await AndroidE2E.launch(screen: "button-test")
        let ui = try await AndroidE2E.describeUI()
        #expect(ui.appPackage == AndroidE2E.playgroundPackage)
    }
}
