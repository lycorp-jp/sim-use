// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation

// E2E coverage for the "system permission alert" loop that sim-use must
// handle in real apps (the LINE login flow dismisses ~6 alert types):
//
//   trigger a system prompt  ->  describe-ui reports it in the SpringBoard
//   / system layer  ->  sim-use taps Allow/Don't-Allow to dismiss it  ->
//   the app's echoed authorization status reflects the choice.
//
// Location is used because `xcrun simctl privacy reset location <bundle>`
// deterministically resets the grant so the prompt reappears on every
// run (notifications are not a `simctl privacy` service). Each test
// resets in setup, so ordering between the allow/deny cases does not
// matter.
//
// Alert button labels are localised (this simulator runs JP); the helper
// taps whichever candidate label is present so the suite is not pinned to
// one locale.
@Suite("Permission Alert Tests", .serialized, .enabled(if: isE2EEnabled))
struct PermissionAlertTests {
    static let bundleID = "com.cameroncooke.SimUsePlayground"
    static let allowWhileUsingLabels = ["Allow While Using App", "アプリの使用中は許可"]
    static let denyLabels = ["Don't Allow", "許可しない"]

    /// Reset the location grant (prompt reappears) then launch the screen.
    static func resetAndLaunch(udid: String) async throws {
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

    /// Tap the request button, poll for the SpringBoard alert, then tap
    /// the first present candidate label. Returns the describe-ui outline
    /// captured while the alert was up (so the caller can assert on the
    /// SpringBoard system-layer signal) and the label that was tapped.
    static func triggerPromptAndTap(
        udid: String,
        labels: [String]
    ) async throws -> (alertDump: String, tappedLabel: String?) {
        try await TestHelpers.runSimUseCommand("tap --id request-location-button", simulatorUDID: udid)

        var alertDump = ""
        var tappedLabel: String?
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let dump = try await TestHelpers.runSimUseCommandAllowFailure("describe-ui", simulatorUDID: udid)
            alertDump = dump.output
            if let label = labels.first(where: { dump.output.contains($0) }) {
                tappedLabel = label
                _ = try await TestHelpers.runSimUseCommand("tap --label \"\(label)\"", simulatorUDID: udid)
                break
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        return (alertDump, tappedLabel)
    }

    @Test("Allow path: sim-use dismisses the system alert and grants when-in-use")
    func allowPath() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        try await Self.resetAndLaunch(udid: udid)

        #expect(try await Self.locationStatus(udid: udid) == "notDetermined",
                "Freshly reset location should start notDetermined")

        let (alertDump, tapped) = try await Self.triggerPromptAndTap(
            udid: udid, labels: Self.allowWhileUsingLabels
        )
        #expect(tapped != nil, "System permission alert did not appear with an Allow button; dump: \(alertDump)")
        #expect(alertDump.contains("SpringBoard"),
                "describe-ui should report the alert in the SpringBoard system layer; header: \(alertDump.prefix(60))")

        let status = try await Self.locationStatus(udid: udid)
        #expect(status == "authorizedWhenInUse",
                "Allow While Using App should grant when-in-use; got \(String(describing: status))")

        // Alert dismissed → the playground is frontmost again.
        let after = try await TestHelpers.runSimUseCommandAllowFailure("describe-ui", simulatorUDID: udid)
        #expect(after.output.contains("App: SimUsePlayground"),
                "Playground should be frontmost after the alert is dismissed; header: \(after.output.prefix(60))")
    }

    @Test("Deny path: sim-use dismisses the system alert and denies")
    func denyPath() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        try await Self.resetAndLaunch(udid: udid)

        let (alertDump, tapped) = try await Self.triggerPromptAndTap(
            udid: udid, labels: Self.denyLabels
        )
        #expect(tapped != nil, "System permission alert did not appear with a Don't-Allow button; dump: \(alertDump)")
        #expect(alertDump.contains("SpringBoard"),
                "describe-ui should report the alert in the SpringBoard system layer; header: \(alertDump.prefix(60))")

        let status = try await Self.locationStatus(udid: udid)
        #expect(status == "denied",
                "Don't Allow should deny; got \(String(describing: status))")

        let after = try await TestHelpers.runSimUseCommandAllowFailure("describe-ui", simulatorUDID: udid)
        #expect(after.output.contains("App: SimUsePlayground"),
                "Playground should be frontmost after the alert is dismissed; header: \(after.output.prefix(60))")
    }
}
