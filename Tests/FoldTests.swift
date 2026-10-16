// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

// Live coverage for multi-display simulators (docs/ai/010-display-routing):
// `ios fold`, and every read path while the app is on the iPhone Duo inner
// display. Needs a booted iPhone Duo (Xcode 27.1+). The suite reads the
// display list from devicectl first and skips itself (not fails) on a
// simulator with one integrated display, so it can sit in the default
// suite list; `make e2e-ios-duo` picks a Duo and runs it there.
//
// The suite leaves the device unfolded or folded as it found it.

@Suite("ios fold (multi-display simulators)", .serialized, .enabled(if: isE2EEnabled))
struct FoldTests {
    private static func json(_ text: String) throws -> [String: Any] {
        let start = try #require(text.firstIndex(of: "{"), "expected JSON, got: \(text.prefix(300))")
        return try #require(
            try JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: Any],
            "expected JSON, got: \(text.prefix(300))"
        )
    }

    /// Integrated displays and the active one, read from devicectl directly
    /// so the gate does not depend on the code under test. Nil when
    /// devicectl cannot answer.
    private static func integratedDisplays(udid: String) async -> (count: Int, activeIsPrimary: Bool?)? {
        guard let (output, _) = try? await CommandRunner.run(
            "xcrun devicectl device info displays --device \(udid) --json-output - --timeout 5 --quiet 2>/dev/null",
            allowFailure: true
        ),
            let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
            let displays = (json["result"] as? [String: Any])?["displays"] as? [[String: Any]]
        else { return nil }
        let integrated = displays.filter { ($0["type"] as? [String: Any])?["integrated"] != nil }
        let active = integrated.first { $0["active"] as? Bool == true }
        return (integrated.count, active.map { $0["primary"] as? Bool == true })
    }

    /// The UDID when it is a multi-display simulator; nil (skip) otherwise.
    private static func duoUDID() async throws -> String? {
        let udid = try TestHelpers.requireSimulatorUDID()
        guard let displays = await integratedDisplays(udid: udid), displays.count > 1 else { return nil }
        return udid
    }

    private static func fold(_ posture: String, udid: String) async throws -> [String: Any] {
        let simUse = try TestHelpers.getSimUsePath()
        let (output, exitCode) = try await CommandRunner.run(
            "\(simUse) ios fold \(posture) --json --udid \(udid) 2>/dev/null", allowFailure: true
        )
        #expect(exitCode == 0, "ios fold \(posture) failed: \(output)")
        return try #require(try json(output)["data"] as? [String: Any])
    }

    /// Runs `body` and puts the hinge back where it was.
    private static func preservingPosture(udid: String, _ body: () async throws -> Void) async throws {
        let wasFolded = await integratedDisplays(udid: udid)?.activeIsPrimary ?? true
        do {
            try await body()
        } catch {
            _ = try? await TestHelpers.runSimUseCommandAllowFailure("ios fold \(wasFolded ? "closed" : "open")", simulatorUDID: udid)
            throw error
        }
        _ = try? await TestHelpers.runSimUseCommandAllowFailure("ios fold \(wasFolded ? "closed" : "open")", simulatorUDID: udid)
    }

    @Test("closed and open are confirmed by the active display; no argument reports the posture")
    func foldRoundTrip() async throws {
        guard let udid = try await Self.duoUDID() else { return }
        try await Self.preservingPosture(udid: udid) {
            let closed = try await Self.fold("closed", udid: udid)
            #expect(closed["confirmed"] as? Bool == true)
            let closedActive = try #require((closed["posture"] as? [String: Any])?["activeDisplay"] as? [String: Any])
            #expect(closedActive["primary"] as? Bool == true)
            #expect(await Self.integratedDisplays(udid: udid)?.activeIsPrimary == true)

            let open = try await Self.fold("open", udid: udid)
            #expect(open["confirmed"] as? Bool == true)
            let openActive = try #require((open["posture"] as? [String: Any])?["activeDisplay"] as? [String: Any])
            #expect(openActive["primary"] as? Bool == false)
            #expect(await Self.integratedDisplays(udid: udid)?.activeIsPrimary == false)

            let report = try await Self.fold("", udid: udid)
            #expect(report["requested"] == nil)
            let posture = try #require(report["posture"] as? [String: Any])
            #expect((posture["integratedDisplays"] as? [String])?.count == 2)
        }
    }

    @Test("an intermediate angle reports the display it observed")
    func halfOpen() async throws {
        guard let udid = try await Self.duoUDID() else { return }
        try await Self.preservingPosture(udid: udid) {
            _ = try await Self.fold("closed", udid: udid)
            let half = try await Self.fold("half", udid: udid)
            #expect(half["confirmed"] as? Bool == true)
            #expect(half["hingeAngle"] as? Double == 130)
            // From closed, a jump to 130° opens the inner display (plan E21).
            let active = try #require((half["posture"] as? [String: Any])?["activeDisplay"] as? [String: Any])
            #expect(active["primary"] as? Bool == false)
        }
    }

    @Test("unfolded: describe-ui names the inner display and its interface size; screenshot captures it")
    func innerDisplayReadPaths() async throws {
        guard let udid = try await Self.duoUDID() else { return }
        let simUse = try TestHelpers.getSimUsePath()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        try await Self.preservingPosture(udid: udid) {
            _ = try await Self.fold("open", udid: udid)
            _ = try await TestHelpers.runSimUseCommand("ios rotate landscape-left", simulatorUDID: udid)

            let (output, _) = try await CommandRunner.run("\(simUse) ui --json --no-raw --udid \(udid) 2>/dev/null")
            let envelope = try Self.json(output)
            let data = try #require(envelope["data"] as? [String: Any])
            let display = try #require(data["display"] as? [String: Any])
            #expect(display["primary"] as? Bool == false)
            #expect(display["kind"] as? String == "integrated")
            #expect(display["rotation"] as? String == "rot90")
            #expect(data["orientation"] as? String == "landscape-left")
            let screen = try #require(data["screen"] as? [String: Any])
            #expect(screen["width"] as? Int == 951)
            #expect(screen["height"] as? Int == 669)
            #expect(envelope["advisory"] == nil, "routing to the inner display needs no advisory: \(String(describing: envelope["advisory"]))")
            #expect((data["outline"] as? String ?? "").contains("951x669  (landscape-left, display "))

            let path = NSTemporaryDirectory() + "duo-inner-\(UUID().uuidString).png"
            defer { try? FileManager.default.removeItem(atPath: path) }
            _ = try await TestHelpers.runSimUseCommand("screenshot --output \(path)", simulatorUDID: udid)
            let (size, _) = try await CommandRunner.run("sips -g pixelWidth -g pixelHeight \(path)")
            #expect(size.contains("pixelWidth: 2853"), "inner display at rot90 is 2853x2007: \(size)")
            #expect(size.contains("pixelHeight: 2007"))
        }
    }

    /// The Playground tap-test screen's "Tap Location: (x, y)" echo.
    private static func tapLocation(udid: String) async throws -> String? {
        let (outline, _) = try await CommandRunner.run("\(try TestHelpers.getSimUsePath()) ui --udid \(udid)")
        return outline.components(separatedBy: "\n").lazy.compactMap { line -> String? in
            guard let range = line.range(of: "Tap Location: ") else { return nil }
            return String(line[range.upperBound...].prefix { $0 != "\"" })
        }.first
    }

    @Test("unfolded: taps land on the inner display at the UI point; type works")
    func innerDisplayInput() async throws {
        guard let udid = try await Self.duoUDID() else { return }
        try await Self.preservingPosture(udid: udid) {
            _ = try await Self.fold("open", udid: udid)
            _ = try await TestHelpers.runSimUseCommand("ios rotate landscape-left", simulatorUDID: udid)
            try await TestHelpers.launchPlaygroundApp(to: "tap-test")
            for (x, y) in [(100, 200), (800, 550)] {
                _ = try await TestHelpers.runSimUseCommand("tap -x \(x) -y \(y) --coordinate-space ui", simulatorUDID: udid)
                try await Task.sleep(nanoseconds: 600_000_000)
                #expect(try await Self.tapLocation(udid: udid) == "(\(x), \(y))")
            }

            _ = try await Self.fold("closed", udid: udid)
            // The text-input screen focuses its field on launch.
            try await TestHelpers.launchPlaygroundApp(to: "text-input")
            _ = try await Self.fold("open", udid: udid)
            let text = "duo\(Int.random(in: 100...999))"
            _ = try await TestHelpers.runSimUseCommand("type \(text)", simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 800_000_000)
            let (outline, _) = try await CommandRunner.run("\(try TestHelpers.getSimUsePath()) ui --udid \(udid)")
            #expect(outline.contains("TextField  \"\(text)\""), "typed text should reach the field: \(outline.prefix(600))")
        }
    }

    @Test("typing keeps working after a fold starts dtuhidd (S6, Device Hub closed)")
    func typingAfterFoldStartsDtuhidd() async throws {
        guard let udid = try await Self.duoUDID() else { return }
        let simUse = try TestHelpers.getSimUsePath()
        try await Self.preservingPosture(udid: udid) {
            // Fold only when needed: a fold report itself starts dtuhidd,
            // which would hide the case under test. A cold boot is folded.
            if await Self.integratedDisplays(udid: udid)?.activeIsPrimary != true {
                _ = try await Self.fold("closed", udid: udid)
            }
            // The text-input screen focuses its field on launch.
            try await TestHelpers.launchPlaygroundApp(to: "text-input")
            // A fresh daemon makes its HID connection with this tap: with
            // Device Hub closed there is no dtuhidd yet, so it is the
            // Indigo transport.
            _ = try await CommandRunner.run("\(simUse) daemon stop --udid \(udid)", allowFailure: true)
            func tapField() async throws {
                let field = try await CommandRunner.run("\(simUse) ui --udid \(udid)").output
                    .components(separatedBy: "\n").first { $0.contains("TextField") }
                let alias = try #require(field?.split(separator: " ").first { $0.hasPrefix("@") }, "no text field: \(String(describing: field))")
                _ = try await TestHelpers.runSimUseCommand("tap \(alias)", simulatorUDID: udid)
            }
            try await tapField()
            // fold talks to dtuhidd, which launchd starts on demand; an
            // active dtuhidd suppresses the legacy keyboard service.
            _ = try await Self.fold("open", udid: udid)
            _ = try await Self.fold("closed", udid: udid)
            try await tapField()
            let text = "hub\(Int.random(in: 100...999))"
            _ = try await TestHelpers.runSimUseCommand("type \(text)", simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 800_000_000)
            let (outline, _) = try await CommandRunner.run("\(simUse) ui --udid \(udid)")
            #expect(outline.contains("TextField  \"\(text)\""), "typed text should reach the field: \(outline.prefix(600))")
        }
    }

    @Test("an inner-display tap reaches the app when the connection was made without dtuhidd (S6)")
    func innerTapAfterIndigoConnection() async throws {
        guard let udid = try await Self.duoUDID() else { return }
        let simUse = try TestHelpers.getSimUsePath()
        try await Self.preservingPosture(udid: udid) {
            if await Self.integratedDisplays(udid: udid)?.activeIsPrimary != true {
                _ = try await Self.fold("closed", udid: udid)
            }
            try await TestHelpers.launchPlaygroundApp(to: "tap-test")
            // A fresh daemon's first touch makes the HID connection on the
            // cover; with Device Hub closed it is the Indigo transport.
            _ = try await CommandRunner.run("\(simUse) daemon stop --udid \(udid)", allowFailure: true)
            _ = try await TestHelpers.runSimUseCommand("tap -x 200 -y 300", simulatorUDID: udid)
            _ = try await Self.fold("open", udid: udid)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            _ = try await TestHelpers.runSimUseCommand("tap -x 300 -y 330", simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 700_000_000)
            #expect(try await Self.tapLocation(udid: udid) == "(300, 330)")
        }
    }

    @Test("unfolded: taps by AX id land on all four corners in every rotation")
    func innerDisplayAXTapsAllRotations() async throws {
        guard let udid = try await Self.duoUDID() else { return }
        try await Self.preservingPosture(udid: udid) {
            _ = try await Self.fold("open", udid: udid)
            for orientation in ["landscape-left", "portrait", "landscape-right", "portrait-upside-down"] {
                _ = try await TestHelpers.runSimUseCommand("ios rotate \(orientation)", simulatorUDID: udid)
                try await TestHelpers.launchPlaygroundApp(to: "orientation-test")
                for corner in ["corner-top-leading", "corner-top-trailing", "corner-bottom-leading", "corner-bottom-trailing"] {
                    _ = try await TestHelpers.runSimUseCommand("tap --id \(corner)", simulatorUDID: udid)
                    try await Task.sleep(nanoseconds: 500_000_000)
                    let ui = try await TestHelpers.getUIState(simulatorUDID: udid)
                    #expect(
                        UIStateParser.findElement(in: ui, withIdentifier: "corner-last-tapped")?.value == corner,
                        "\(orientation): \(corner) should land"
                    )
                }
            }
            _ = try await TestHelpers.runSimUseCommand("ios rotate landscape-left", simulatorUDID: udid)
        }
    }

    @Test("unfolded: a swipe and a gesture preset reach the inner display")
    func innerDisplaySwipe() async throws {
        guard let udid = try await Self.duoUDID() else { return }
        try await Self.preservingPosture(udid: udid) {
            _ = try await Self.fold("open", udid: udid)
            try await TestHelpers.launchPlaygroundApp(to: "swipe-test")
            _ = try await TestHelpers.runSimUseCommand(
                "swipe --start-x 200 --start-y 400 --end-x 700 --end-y 400 --coordinate-space ui", simulatorUDID: udid
            )
            _ = try await TestHelpers.runSimUseCommand("gesture scroll-up", simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 800_000_000)
            let ui = try await TestHelpers.getUIState(simulatorUDID: udid)
            let count = UIStateParser.findElementContainingLabel(in: ui, containing: "Count:")?.label
            #expect(count == "Count: 2", "both swipes should register: \(String(describing: count))")
        }
    }

    @Test("ios rotate turns the inner display through all four orientations")
    func rotateInnerDisplay() async throws {
        guard let udid = try await Self.duoUDID() else { return }
        try await TestHelpers.launchPlaygroundApp(to: "orientation-test")
        try await Self.preservingPosture(udid: udid) {
            _ = try await Self.fold("open", udid: udid)
            let simUse = try TestHelpers.getSimUsePath()
            for orientation in ["portrait", "landscape-right", "portrait-upside-down", "landscape-left"] {
                let (output, _) = try await CommandRunner.run("\(simUse) ios rotate \(orientation) --json --udid \(udid) 2>/dev/null")
                let rotate = try #require((try Self.json(output)["data"] as? [String: Any])?["rotate"] as? [String: Any])
                #expect(rotate["confirmed"] as? Bool == true, "\(orientation): \(output.prefix(300))")
                #expect(rotate["orientation"] as? String == orientation)
            }
        }
    }

    @Test("unfolding ends a Resize Mode session, and the next commands see it at once (R157-01)")
    func unfoldEndsResizeSession() async throws {
        guard let udid = try await Self.duoUDID() else { return }
        let simUse = try TestHelpers.getSimUsePath()
        try await Self.preservingPosture(udid: udid) {
            _ = try await Self.fold("closed", udid: udid)
            _ = try await TestHelpers.runSimUseCommand("ios rotate portrait", simulatorUDID: udid)
            try await TestHelpers.launchPlaygroundApp(to: "tap-test")

            // A Resize Mode session lives as long as this process.
            let session = Process()
            session.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            session.arguments = ["devicectl", "device", "appResize", "start", "--device", udid, "--preferred-size", "560x874"]
            session.standardOutput = FileHandle.nullDevice
            session.standardError = FileHandle.nullDevice
            try session.run()
            defer { if session.isRunning { session.terminate() } }

            // Warm the daemon's session cache with an active answer.
            var sawSession = false
            for _ in 0..<20 {
                let (output, _) = try await CommandRunner.run("\(simUse) ui --json --no-raw --udid \(udid) 2>/dev/null", allowFailure: true)
                let display = ((try? Self.json(output))?["data"] as? [String: Any])?["display"] as? [String: Any]
                if display?["kind"] as? String == "virtual" {
                    sawSession = true
                    break
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            guard sawSession else {
                Issue.record("Resize Mode session never became active; cannot check R157-01")
                return
            }

            let open = try await Self.fold("open", udid: udid)
            #expect((open["posture"] as? [String: Any])?["resizableSession"] == nil, "fold must not report the ended session: \(open)")

            let (output, _) = try await CommandRunner.run("\(simUse) ui --json --no-raw --udid \(udid) 2>/dev/null")
            let display = (try Self.json(output)["data"] as? [String: Any])?["display"] as? [String: Any]
            #expect(display?["kind"] as? String == "integrated", "the inner display hosts the app now: \(String(describing: display))")

            let rotate = try await TestHelpers.runSimUseCommandAllowFailure("ios rotate portrait", simulatorUDID: udid)
            #expect(rotate.exitCode == 0, "rotation must not be refused by a stale session: \(rotate.output)")
        }
    }

    @Test("a fold clears the describe-ui snapshot")
    func foldClearsSnapshot() async throws {
        guard let udid = try await Self.duoUDID() else { return }
        try await Self.preservingPosture(udid: udid) {
            // Snapshot on the inner display, then fold: the cover display
            // has another geometry, and the @N table must not be reused.
            _ = try await Self.fold("open", udid: udid)
            _ = try await TestHelpers.runSimUseCommand("ui", simulatorUDID: udid)
            _ = try await Self.fold("closed", udid: udid)
            let result = try await TestHelpers.runSimUseCommandAllowFailure("tap @1", simulatorUDID: udid)
            #expect(result.exitCode != 0)
            #expect(result.output.contains("No describe-ui snapshot"))
        }
    }
}
