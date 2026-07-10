// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation

// E2E coverage for sim-use's AX→HID orientation self-calibration
// against the SimUsePlayground `orientation-test` screen.
//
// The screen rotates itself via `UIWindowScene.requestGeometryUpdate`
// and exposes four corner probes addressable by AX id plus a
// `corner-last-tapped` echo. After a rotation the AX tree is reported in
// the new (landscape) UI space while HID input stays in the native
// portrait framebuffer; sim-use must transform an AX-id tap so it lands
// on the intended corner. Each test asserts the echo matches the corner
// it addressed — a mislanded tap (broken calibration) echoes a different
// corner or none.
//
// Portrait is always restored at the end of each test (pass or fail) so
// the shared simulator is left in a known state for sibling suites.
@Suite("Orientation Calibration Tests", .serialized, .enabled(if: isE2EEnabled))
struct OrientationTests {
    /// Tap the portrait button by AX id and wait for the rotation to
    /// settle. Best-effort — never throws, so it is safe as cleanup.
    static func restorePortrait(udid: String) async {
        _ = try? await TestHelpers.runSimUseCommandAllowFailure(
            "tap --id rotate-portrait-button",
            simulatorUDID: udid
        )
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    /// Run `body`, restoring portrait afterwards whether or not it threw.
    static func withPortraitRestore(udid: String, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await restorePortrait(udid: udid)
            throw error
        }
        await restorePortrait(udid: udid)
    }

    static func orientationValue(udid: String) async throws -> String? {
        let ui = try await TestHelpers.getUIState(simulatorUDID: udid)
        return UIStateParser.findElement(in: ui, withIdentifier: "current-orientation")?.value
    }

    static func lastTappedCorner(udid: String) async throws -> String? {
        let ui = try await TestHelpers.getUIState(simulatorUDID: udid)
        return UIStateParser.findElement(in: ui, withIdentifier: "corner-last-tapped")?.value
    }

    @Test("Corner tap by AX id lands correctly after rotating to landscape")
    func cornerTapLandsAfterLandscapeRotation() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        try await TestHelpers.launchPlaygroundApp(to: "orientation-test")

        try await Self.withPortraitRestore(udid: udid) {
            // Rotate to landscape via the on-screen button (tapped by id).
            try await TestHelpers.runSimUseCommand("tap --id rotate-landscape-button", simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 1_800_000_000)

            let orientation = try await Self.orientationValue(udid: udid)
            #expect(orientation?.contains("landscape") == true,
                    "Screen should report a landscape orientation; got \(String(describing: orientation))")

            // Tap a corner by AX id — calibration must map UI-space frame
            // to the native-portrait HID point so this lands on the probe.
            try await TestHelpers.runSimUseCommand("tap --id corner-top-trailing", simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 800_000_000)

            let corner = try await Self.lastTappedCorner(udid: udid)
            #expect(corner == "corner-top-trailing",
                    "Tapping corner-top-trailing in landscape should echo it; got \(String(describing: corner))")
        }
    }

    @Test("Corner tap by AX id lands correctly back in portrait")
    func cornerTapLandsAfterReturnToPortrait() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        try await TestHelpers.launchPlaygroundApp(to: "orientation-test")

        try await Self.withPortraitRestore(udid: udid) {
            // Landscape round-trip, then back to portrait, to prove
            // calibration re-tracks the orientation both ways.
            try await TestHelpers.runSimUseCommand("tap --id rotate-landscape-button", simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 1_800_000_000)

            try await TestHelpers.runSimUseCommand("tap --id rotate-portrait-button", simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 1_800_000_000)

            let orientation = try await Self.orientationValue(udid: udid)
            #expect(orientation == "portrait",
                    "Screen should report portrait after rotating back; got \(String(describing: orientation))")

            try await TestHelpers.runSimUseCommand("tap --id corner-bottom-leading", simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 800_000_000)

            let corner = try await Self.lastTappedCorner(udid: udid)
            #expect(corner == "corner-bottom-leading",
                    "Tapping corner-bottom-leading in portrait should echo it; got \(String(describing: corner))")
        }
    }
}
