// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore
import Testing

// Live coverage for explicit coordinates in UI space by default
// (docs/ai/010-display-routing, S3): numbers read from `ui` land where
// they were read, in every orientation, for tap, swipe, touch and the
// two-finger verbs; `--coordinate-space native` keeps the old mapping.
// Runs on any booted iOS simulator — on an iPhone Duo, fold it closed
// first or run it on the inner display; both route through the same
// calibration. Every test restores portrait on the way out.

@Suite("Explicit coordinates default to UI space", .serialized, .enabled(if: isE2EEnabled))
struct UICoordinateDefaultTests {
    private static let corners = [
        "corner-top-leading", "corner-top-trailing", "corner-bottom-leading", "corner-bottom-trailing",
    ]

    private static func restorePortrait(udid: String) async {
        _ = try? await TestHelpers.runSimUseCommandAllowFailure("ios rotate portrait", simulatorUDID: udid)
    }

    /// Rotates and reports whether the device really turned: an iPhone
    /// may keep portrait for `portrait-upside-down`.
    private static func rotate(_ orientation: String, udid: String) async throws -> Bool {
        let simUse = try TestHelpers.getSimUsePath()
        let (output, _) = try await CommandRunner.run(
            "\(simUse) ios rotate \(orientation) --json --udid \(udid) 2>/dev/null", allowFailure: true
        )
        try await Task.sleep(nanoseconds: 800_000_000)
        return output.contains("\"confirmed\":true") || output.contains("\"confirmed\" : true")
    }

    private static func element(_ id: String, in root: UIElement) -> UIElement? {
        UIStateParser.findElement(in: root, withIdentifier: id)
    }

    private static func center(of id: String, in root: UIElement) throws -> (x: Int, y: Int) {
        let frame = try #require(element(id, in: root)?.frame, "no frame for \(id)")
        return (Int((frame.x + frame.width / 2).rounded()), Int((frame.y + frame.height / 2).rounded()))
    }

    /// The app's own frame: the gesture areas are `Color.clear` views
    /// that the accessibility tree does not expose.
    private static func screen(_ root: UIElement) throws -> UIElement.Frame {
        try #require(root.frame, "no root frame")
    }

    private static func value(_ id: String, udid: String) async throws -> String? {
        element(id, in: try await TestHelpers.getUIState(simulatorUDID: udid))?.value
    }

    /// These screens set a screen-level accessibility identifier, which
    /// replaces every child's id: find their read-outs by label.
    private static func label(containing prefix: String, udid: String) async throws -> String? {
        UIStateParser.findElementContainingLabel(
            in: try await TestHelpers.getUIState(simulatorUDID: udid), containing: prefix
        )?.label
    }

    /// Runs `body` in `orientation` and restores portrait afterwards,
    /// also on failure, so later suites start upright. Skips when the
    /// device keeps another orientation.
    private static func inOrientation(
        _ orientation: String, screen: String, udid: String,
        _ body: () async throws -> Void
    ) async throws {
        try await TestHelpers.launchPlaygroundApp(to: screen)
        do {
            if try await rotate(orientation, udid: udid) {
                try await body()
            }
        } catch {
            await restorePortrait(udid: udid)
            throw error
        }
        await restorePortrait(udid: udid)
    }

    @Test("tap -x/-y read from ui lands on every corner", arguments: [
        "portrait", "landscape-left", "landscape-right", "portrait-upside-down",
    ])
    func cornerTaps(orientation: String) async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        try await Self.inOrientation(orientation, screen: "orientation-test", udid: udid) {

            let root = try await TestHelpers.getUIState(simulatorUDID: udid)
            for corner in Self.corners {
                let point = try Self.center(of: corner, in: root)
                try await TestHelpers.runSimUseCommand("tap -x \(point.x) -y \(point.y)", simulatorUDID: udid)
                try await Task.sleep(nanoseconds: 400_000_000)
                #expect(try await Self.value("corner-last-tapped", udid: udid) == corner, "\(orientation): tap at \(point) should hit \(corner)")
            }
        }
    }

    @Test("without a describe-ui snapshot the tree calibrates instead")
    func cornerTapWithoutSnapshot() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        try await Self.inOrientation("landscape-right", screen: "orientation-test", udid: udid) {

            let root = try await TestHelpers.getUIState(simulatorUDID: udid)
            let point = try Self.center(of: "corner-bottom-trailing", in: root)
            OutlineCache.invalidate(udid: udid)
            try await TestHelpers.runSimUseCommand("tap -x \(point.x) -y \(point.y)", simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 400_000_000)
            #expect(try await Self.value("corner-last-tapped", udid: udid) == "corner-bottom-trailing")
        }
    }

    @Test("--coordinate-space native keeps the native mapping")
    func nativeOptOut() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        try await Self.inOrientation("landscape-left", screen: "orientation-test", udid: udid) {

            let root = try await TestHelpers.getUIState(simulatorUDID: udid)
            let before = Self.element("corner-last-tapped", in: root)?.value
            let point = try Self.center(of: "corner-top-trailing", in: root)
            // A landscape UI point read as native portrait points lands
            // somewhere else on the screen — not on this corner.
            try await TestHelpers.runSimUseCommand(
                "tap -x \(point.x) -y \(point.y) --coordinate-space native", simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 400_000_000)
            let after = try await Self.value("corner-last-tapped", udid: udid)
            #expect(after != "corner-top-trailing" || before == "corner-top-trailing")
        }
    }

    @Test("swipe endpoints read from ui are where the app sees them", arguments: ["portrait", "landscape-right"])
    func swipeEndpoints(orientation: String) async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        try await Self.inOrientation(orientation, screen: "swipe-test", udid: udid) {

            let root = try await TestHelpers.getUIState(simulatorUDID: udid)
            let area = try Self.screen(root)
            let start = (x: Int(area.x + area.width * 0.3), y: Int(area.y + area.height * 0.7))
            let end = (x: Int(area.x + area.width * 0.7), y: Int(area.y + area.height * 0.6))
            try await TestHelpers.runSimUseCommand(
                "swipe --start-x \(start.x) --start-y \(start.y) --end-x \(end.x) --end-y \(end.y) --duration 0.5",
                simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 600_000_000)

            let seenStart = try #require(CoordinateParser.parseCoordinates(from: try await Self.label(containing: "Start:", udid: udid) ?? ""))
            // The recognizer reports the first point after its slop, so
            // the start sits a few points along the stroke.
            #expect(abs(seenStart.x - start.x) <= 25 && abs(seenStart.y - start.y) <= 25,
                    "\(orientation): swipe started at \(seenStart), expected near \(start)")
        }
    }

    @Test("split touch --down / --up lands where ui reads it in landscape")
    func splitTouch() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        try await Self.inOrientation("landscape-left", screen: "touch-control", udid: udid) {

            let root = try await TestHelpers.getUIState(simulatorUDID: udid)
            let area = try Self.screen(root)
            // The playground reports a touch in its area's own space, whose
            // origin the tree does not expose: compare two touches instead.
            func touch(_ x: Int, _ y: Int) async throws -> (x: Int, y: Int) {
                try await TestHelpers.runSimUseCommand("touch -x \(x) -y \(y) --down", simulatorUDID: udid)
                try await TestHelpers.runSimUseCommand("touch -x \(x) -y \(y) --up", simulatorUDID: udid)
                try await Task.sleep(nanoseconds: 500_000_000)
                return try #require(CoordinateParser.parseCoordinates(
                    from: try await Self.label(containing: "Last touch down:", udid: udid) ?? ""))
            }
            let first = (x: Int(area.x + area.width * 0.55), y: Int(area.y + area.height * 0.6))
            let second = (x: first.x + 150, y: first.y + 60)
            let a = try await touch(first.x, first.y)
            let b = try await touch(second.x, second.y)
            #expect(abs((b.x - a.x) - 150) <= 2 && abs((b.y - a.y) - 60) <= 2,
                    "touches moved by \((b.x - a.x, b.y - a.y)), expected (150, 60)")
        }
    }

    /// The playground recognizes only the first pinch after a launch (a
    /// second pinch is missed in either coordinate space), so each case
    /// starts from a fresh launch.
    @Test("pinch by preset and by multi-touch is recognized in landscape", arguments: [
        ("gesture pinch-out --radius 40", "pinch-out"),
        ("gesture pinch-in --radius 120", "pinch-in"),
        ("multi-touch", "pinch-out"),
        ("batch", "pinch-in"),
    ])
    func pinchInLandscape(command: String, expected: String) async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        try await Self.inOrientation("landscape-right", screen: "gesture-presets", udid: udid) {
            let root = try await TestHelpers.getUIState(simulatorUDID: udid)
            let area = try Self.screen(root)
            let cx = Int(area.x + area.width / 2)
            let cy = Int(area.y + area.height / 2)
            let argv: String
            switch command {
            case "multi-touch":
                argv = "multi-touch --x1 \(cx - 30) --y1 \(cy) --x2 \(cx + 30) --y2 \(cy)"
                    + " --x1-end \(cx - 130) --y1-end \(cy) --x2-end \(cx + 130) --y2-end \(cy)"
            case "batch":
                // A batch step sends the same two-finger trajectory.
                argv = "ios batch --step 'gesture pinch-in --radius 120 --center-x \(cx) --center-y \(cy)'"
            default:
                argv = "\(command) --center-x \(cx) --center-y \(cy)"
            }
            try await TestHelpers.runSimUseCommand(argv, simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            #expect(try await Self.label(containing: "Latest Gesture:", udid: udid) == "Latest Gesture: \(expected)")
        }
    }
}
