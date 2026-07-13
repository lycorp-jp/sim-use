// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation

// E2E coverage for the "system permission alert" loop that sim-use must
// handle in real apps (the LINE login flow dismisses ~6 alert types):
//
//   trigger a system prompt  ->  describe-ui reports it in the SpringBoard
//   / system layer  ->  sim-use taps the button to dismiss it  ->  the
//   app's echoed authorization status reflects the choice.
//
// Location is used because `xcrun simctl privacy reset location <bundle>`
// deterministically resets the grant so the prompt reappears on every
// run (notifications are not a `simctl privacy` service). Each test
// resets in setup, so ordering between the allow/deny cases does not
// matter.
//
// Button selection is by POSITIONAL LIST ALIAS, not by label. SpringBoard
// permission-alert buttons carry no accessibility id or resource-id (both
// null in describe-ui --json), only a localised label — and the label is a
// trap: on an English simulator "Don’t Allow" uses a U+2019 curly
// apostrophe, so an ASCII "Don't Allow" match silently misses, leaving the
// alert on screen where it then bleeds into every later suite. The button
// list is stable in order across locales (Apple orders it semantically):
//   #1@1  Allow Once           / 1度だけ許可
//   #2@1  Allow While Using App / アプリの使用中は許可
//   #3@1  Don't Allow          / 許可しない
// (This is the iOS "when in use" 3-button prompt; the status assertions
// below catch it if that layout ever changes.)
@Suite("Permission Alert Tests", .serialized, .enabled(if: isE2EEnabled))
struct PermissionAlertTests {
    static let bundleID = "com.cameroncooke.SimUsePlayground"
    static let allowWhileUsingAlias = "#2@1"
    static let denyAlias = "#3@1"

    static func header(udid: String) async throws -> String {
        (try await TestHelpers.runSimUseCommandAllowFailure("describe-ui", simulatorUDID: udid)).output
    }

    /// Reset the location grant (prompt reappears) then launch the screen.
    /// Clears any stray system alert first so a prior test that ended before
    /// its dismiss tap cannot leak the prompt into this one.
    static func resetAndLaunch(udid: String) async throws {
        await dismissStrayAlert(udid: udid)
        _ = try await CommandRunner.run(
            "xcrun simctl privacy \(udid) reset location \(bundleID)",
            allowFailure: true
        )
        try await TestHelpers.launchPlaygroundApp(to: "permissions-test", simulatorUDID: udid)
    }

    static func locationStatus(udid: String) async throws -> String? {
        let ui = try await TestHelpers.getUIState(simulatorUDID: udid)
        return UIStateParser.findElement(in: ui, withIdentifier: "location-status")?.value
    }

    /// Tap the request button and poll describe-ui until the system alert is
    /// frontmost (SpringBoard). Returns the outline captured while it was up.
    /// The final poll leaves a fresh alias snapshot so `#N@1` resolves next.
    static func triggerPromptAndWait(udid: String) async throws -> String {
        try await TestHelpers.runSimUseCommand("tap --id request-location-button", simulatorUDID: udid)
        var dump = ""
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            dump = (try await TestHelpers.runSimUseCommandAllowFailure("describe-ui", simulatorUDID: udid)).output
            if dump.contains("App: SpringBoard") { break }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        return dump
    }

    /// Best-effort: if a system alert is frontmost, clear it by tapping the
    /// first button (harmless — every test resets the grant in setup). Called
    /// before each test so an earlier failure cannot cascade.
    static func dismissStrayAlert(udid: String) async {
        guard let head = try? await header(udid: udid), head.contains("App: SpringBoard") else { return }
        _ = try? await TestHelpers.runSimUseCommandAllowFailure("tap '#1@1'", simulatorUDID: udid)
    }

    @Test("Allow path: sim-use dismisses the system alert and grants when-in-use")
    func allowPath() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        try await Self.resetAndLaunch(udid: udid)

        #expect(try await Self.locationStatus(udid: udid) == "notDetermined",
                "Freshly reset location should start notDetermined")

        let alertDump = try await Self.triggerPromptAndWait(udid: udid)
        #expect(alertDump.contains("App: SpringBoard"),
                "describe-ui should report the alert in the SpringBoard system layer; header: \(alertDump.prefix(60))")

        try await TestHelpers.runSimUseCommand("tap '\(Self.allowWhileUsingAlias)'", simulatorUDID: udid)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let status = try await Self.locationStatus(udid: udid)
        #expect(status == "authorizedWhenInUse",
                "Allow While Using App (\(Self.allowWhileUsingAlias)) should grant when-in-use; got \(String(describing: status))")

        // Alert dismissed → the playground is frontmost again.
        let after = try await Self.header(udid: udid)
        #expect(after.contains("App: SimUsePlayground"),
                "Playground should be frontmost after the alert is dismissed; header: \(after.prefix(60))")
    }

    @Test("Deny path: sim-use dismisses the system alert and denies")
    func denyPath() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        try await Self.resetAndLaunch(udid: udid)

        let alertDump = try await Self.triggerPromptAndWait(udid: udid)
        #expect(alertDump.contains("App: SpringBoard"),
                "describe-ui should report the alert in the SpringBoard system layer; header: \(alertDump.prefix(60))")

        try await TestHelpers.runSimUseCommand("tap '\(Self.denyAlias)'", simulatorUDID: udid)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let status = try await Self.locationStatus(udid: udid)
        #expect(status == "denied",
                "Don't Allow (\(Self.denyAlias)) should deny; got \(String(describing: status))")

        let after = try await Self.header(udid: udid)
        #expect(after.contains("App: SimUsePlayground"),
                "Playground should be frontmost after the alert is dismissed; header: \(after.prefix(60))")
    }
}
