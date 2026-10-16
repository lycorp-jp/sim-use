// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

// Live coverage for `sim-use ios rotate` (docs/ai/010-display-routing).
// Runs on any booted iOS simulator: a single-display device rotates
// through the Purple GSEvent path, an iPhone Duo through the orientation
// picker report. The Playground `orientation-test` screen supports every
// orientation and echoes both its interface orientation and the corner
// probe a tap hit, so each test proves two things: the device really
// turned, and a tap by AX id still lands after a *device* rotation (the
// older OrientationTests only cover app-forced rotation).
//
// Every test restores portrait on the way out so sibling suites start
// from a known state.

@Suite("ios rotate (device rotation)", .serialized, .enabled(if: isE2EEnabled))
struct RotateTests {
    private static func json(_ text: String) throws -> [String: Any] {
        let start = try #require(text.firstIndex(of: "{"), "expected JSON, got: \(text.prefix(300))")
        return try #require(
            try JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: Any],
            "expected JSON, got: \(text.prefix(300))"
        )
    }

    private static func rotate(_ orientation: String, udid: String) async throws -> [String: Any] {
        let simUse = try TestHelpers.getSimUsePath()
        let (output, exitCode) = try await CommandRunner.run(
            "\(simUse) ios rotate \(orientation) --json --udid \(udid) 2>/dev/null", allowFailure: true
        )
        #expect(exitCode == 0, "ios rotate \(orientation) failed: \(output)")
        return try json(output)
    }

    private static func restorePortrait(udid: String) async {
        _ = try? await TestHelpers.runSimUseCommandAllowFailure("ios rotate portrait", simulatorUDID: udid)
    }

    /// On a multi-display simulator these tests run on the primary display:
    /// fold it closed. `ios fold` refuses a single-display simulator, which
    /// is fine — it is already on its only display.
    private static func usePrimaryDisplay(udid: String) async {
        _ = try? await TestHelpers.runSimUseCommandAllowFailure("ios fold closed", simulatorUDID: udid)
    }

    private static func element(_ id: String, udid: String) async throws -> String? {
        let ui = try await TestHelpers.getUIState(simulatorUDID: udid)
        return UIStateParser.findElement(in: ui, withIdentifier: id)?.value
    }

    @Test("landscape-left and landscape-right are confirmed, shown by the app, and AX-id taps land", arguments: [
        ("landscape-left", "landscapeLeft"),
        ("landscape-right", "landscapeRight"),
    ])
    func landscape(orientation: String, uiKitName: String) async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        await Self.usePrimaryDisplay(udid: udid)
        try await TestHelpers.launchPlaygroundApp(to: "orientation-test")
        defer { Task { await Self.restorePortrait(udid: udid) } }

        let envelope = try await Self.rotate(orientation, udid: udid)
        let rotate = try #require((envelope["data"] as? [String: Any])?["rotate"] as? [String: Any])
        #expect(rotate["confirmed"] as? Bool == true)
        #expect(rotate["orientation"] as? String == orientation)
        #expect(envelope["advisory"] == nil)

        // The app sees the same interface orientation.
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(try await Self.element("current-orientation", udid: udid) == uiKitName)

        // The outline header carries the tag.
        let (outline, _) = try await CommandRunner.run("\(try TestHelpers.getSimUsePath()) ui --udid \(udid)")
        #expect(outline.contains("(\(orientation)"), "header should carry the orientation tag: \(outline.prefix(200))")

        // A tap by AX id lands on the addressed corner after a device rotation.
        for corner in ["corner-top-trailing", "corner-bottom-leading"] {
            try await TestHelpers.runSimUseCommand("tap --id \(corner)", simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 500_000_000)
            #expect(try await Self.element("corner-last-tapped", udid: udid) == corner)
        }

        let back = try await Self.rotate("portrait", udid: udid)
        #expect(((back["data"] as? [String: Any])?["rotate"] as? [String: Any])?["confirmed"] as? Bool == true)
    }

    @Test("a rotation clears the describe-ui snapshot, so stale @N aliases cannot tap")
    func clearsSnapshot() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        await Self.usePrimaryDisplay(udid: udid)
        try await TestHelpers.launchPlaygroundApp(to: "orientation-test")
        defer { Task { await Self.restorePortrait(udid: udid) } }

        _ = try await TestHelpers.runSimUseCommand("ui", simulatorUDID: udid)
        _ = try await Self.rotate("landscape-left", udid: udid)
        let result = try await TestHelpers.runSimUseCommandAllowFailure("tap @1", simulatorUDID: udid)
        #expect(result.exitCode != 0)
        #expect(result.output.contains("No describe-ui snapshot"), "unexpected: \(result.output.prefix(300))")
    }

    @Test("an orientation the app does not accept succeeds unconfirmed, with an advisory")
    func unsupportedOrientation() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        // The Playground main list does not restrict orientations, but an
        // iPhone-size screen refuses portrait-upside-down; on an iPad the
        // rotation is simply confirmed. Either answer must be honest.
        await Self.usePrimaryDisplay(udid: udid)
        try await TestHelpers.launchPlaygroundApp(to: "orientation-test")
        defer { Task { await Self.restorePortrait(udid: udid) } }

        let envelope = try await Self.rotate("portrait-upside-down", udid: udid)
        let rotate = try #require((envelope["data"] as? [String: Any])?["rotate"] as? [String: Any])
        if rotate["confirmed"] as? Bool == true {
            #expect(rotate["orientation"] as? String == "portrait-upside-down")
        } else {
            let advisory = try #require(envelope["advisory"] as? [String: Any])
            #expect((advisory["message"] as? String ?? "").contains("does not accept portrait-upside-down"))
            #expect(rotate["orientation"] as? String != "portrait-upside-down")
        }
    }

    @Test("bad orientation names are rejected before anything is sent")
    func rejectsBadName() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let result = try await TestHelpers.runSimUseCommandAllowFailure("ios rotate sideways", simulatorUDID: udid)
        #expect(result.exitCode != 0)
        #expect(result.output.contains("Orientation must be one of"))
    }
}
