// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

// Live coverage for Xcode 27 Resize Mode (issue #143): routing to the
// `Resizable` display (docs/ai/010-display-routing). Needs
// a booted iOS 27+ simulator on an Xcode 27 toolchain: the suite probes
// `devicectl device info appResize` first and skips itself (not fails)
// when CoreDevice cannot host a session — on Xcode 26 legs of the E2E
// matrix, for instance. Like the other SIM_USE_E2E suites it drives the
// real CLI against the Playground fixture.
//
// The session is started the way users start it — a backgrounded
// `devicectl device appResize start` — and ended by terminating that
// process, which CoreDevice treats as the end of the session. Every test
// ends its own session on the way out so a failure cannot leave the
// simulator resized for the suites that follow.

@Suite("Resize Mode (resizable app session)", .serialized, .enabled(if: isE2EEnabled))
struct ResizeModeTests {
    private static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])

    /// A running `devicectl device appResize start`. CoreDevice ends the
    /// session when this process exits.
    private final class Session {
        let process = Process()
        let udid: String

        init(udid: String, size: String) throws {
            self.udid = udid
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["devicectl", "device", "appResize", "start", "--device", udid, "--preferred-size", size]
            var environment = ProcessInfo.processInfo.environment
            if let developerDir = environment["SIM_USE_TEST_DEVELOPER_DIR"], !developerDir.isEmpty {
                environment["DEVELOPER_DIR"] = developerDir
            }
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        func end() async {
            if process.isRunning { process.terminate() }
            // Poll instead of `waitUntilExit()`: after `terminate()` on a
            // process launched off the main thread, it can sleep in its
            // run loop forever even though the child is already reaped.
            while process.isRunning {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            // CoreDevice tears the display's session down shortly after
            // the client goes away; wait for it so the next test (or
            // suite) starts from a resolved state.
            for _ in 0..<20 {
                if await ResizeModeTests.sessionState(udid: udid) == .inactive { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private enum SessionState: Equatable { case active, inactive, unsupported }

    /// Mirrors `ResizableAppSessionProbe.classify` on the raw devicectl
    /// document, so the suite does not depend on the code under test to
    /// decide whether it can run.
    private static func sessionState(udid: String) async -> SessionState {
        guard let (output, _) = try? await CommandRunner.run(
            "xcrun devicectl device info appResize --device \(udid) --json-output - --timeout 5 --quiet 2>/dev/null",
            allowFailure: true
        ) else { return .unsupported }
        guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
            return .unsupported
        }
        if json["result"] != nil { return .active }
        if let error = json["error"] as? [String: Any], (error["code"] as? Int) == 24004 { return .inactive }
        return .unsupported
    }

    /// Starts a session and waits for CoreDevice to report it. Returns nil
    /// (after recording why) when the environment cannot host one.
    private static func startSession(udid: String, size: String = "560x874") async throws -> Session? {
        let before = await sessionState(udid: udid)
        guard before != .unsupported else { return nil }
        let session = try Session(udid: udid, size: size)
        for _ in 0..<20 {
            if await sessionState(udid: udid) == .active { return session }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        await session.end()
        throw TestError.unexpectedState("devicectl appResize start did not produce an active session within 10 s")
    }

    private static func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], "expected JSON, got: \(text.prefix(300))")
    }

    /// The Playground tap-test screen's echo of the last tap, e.g. "(100, 300)".
    private static func tapEcho(_ outline: String) -> (count: String?, location: String?) {
        func value(after prefix: String) -> String? {
            outline.components(separatedBy: "\n").lazy.compactMap { line -> String? in
                guard let range = line.range(of: prefix) else { return nil }
                return String(line[range.upperBound...].prefix { $0 != "\"" })
            }.first
        }
        return (value(after: "Tap Count: "), value(after: "Tap Location: "))
    }

    @Test("ui names the Resizable display and keeps the tree to the app's own process")
    func describeUIRoutesToResizable() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        guard let session = try await Self.startSession(udid: udid) else {
            // Not an Xcode 27 / iOS 27 environment — nothing to verify.
            return
        }
        defer { Task { await session.end() } }

        let (stdout, _) = try await CommandRunner.run("\(simUse) ui --udid \(udid) --json")
        let envelope = try Self.json(stdout)
        let data = try #require(envelope["data"] as? [String: Any])
        let display = try #require(data["display"] as? [String: Any])
        #expect(display["name"] as? String == "Resizable")
        #expect(display["kind"] as? String == "virtual")
        let screen = try #require(data["screen"] as? [String: Any])
        #expect(screen["width"] as? Int == 560, "scene width should be the requested 560, got \(String(describing: screen["width"]))")
        #expect(data["orientation"] as? String == "portrait")
        #expect((data["outline"] as? String ?? "").contains("(display Resizable 560x874)"))

        // No SpringBoard splicing: every node is the app's own process.
        var pids = Set<Int>()
        func walk(_ node: [String: Any]) {
            if let pid = node["pid"] as? Int { pids.insert(pid) }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        for root in data["raw"] as? [[String: Any]] ?? [] { walk(root) }
        #expect(pids.count == 1, "expected one pid in the tree, got \(pids)")

        await session.end()
    }

    @Test("touch input lands in the resized app at the requested point")
    func touchLandsInSession() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        guard let session = try await Self.startSession(udid: udid) else { return }
        defer { Task { await session.end() } }
        _ = try await CommandRunner.run("\(simUse) ui --udid \(udid)", allowFailure: true)

        _ = try await CommandRunner.run("\(simUse) tap --udid \(udid) -x 100 -y 300")
        _ = try await CommandRunner.run("\(simUse) tap --udid \(udid) -x 450 -y 650")
        try await Task.sleep(nanoseconds: 800_000_000)
        let (outline, _) = try await CommandRunner.run("\(simUse) ui --udid \(udid)")
        let echo = Self.tapEcho(outline)
        #expect(echo.count == "2", "both taps should land: \(outline.prefix(600))")
        #expect(echo.location == "(450, 650)", "the scene point must land exactly: \(String(describing: echo.location))")

        // A batch touch step lands as well.
        let batchFile = FileManager.default.temporaryDirectory.appendingPathComponent("resize-batch-\(UUID().uuidString).txt")
        try "tap -x 200 -y 500\n".write(to: batchFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: batchFile) }
        _ = try await CommandRunner.run("\(simUse) ios batch --udid \(udid) --file \(batchFile.path)")
        try await Task.sleep(nanoseconds: 800_000_000)
        let (afterBatch, _) = try await CommandRunner.run("\(simUse) ui --udid \(udid)")
        #expect(Self.tapEcho(afterBatch).location == "(200, 500)")

        // A selector tap: the back button returns to the Playground home.
        _ = try await CommandRunner.run("\(simUse) tap --udid \(udid) --id BackButton")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let (home, _) = try await CommandRunner.run("\(simUse) ui --udid \(udid)")
        #expect(home.contains("Touch & Gestures"), "the back button tap should land: \(home.prefix(400))")

        await session.end()
    }

    @Test("a session that starts inside a stale no-session cache window still gets its touches (R150-02, R150-05)")
    func touchInsideStaleCacheWindowLands() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        // Warm "no session", then start a session whose scene is the
        // device's 402x874 scaled uniformly. The selector tap's tree fetch
        // sees the new root size and re-reads the session, so the touch
        // goes to the Resizable display instead of the main one.
        _ = try await CommandRunner.run("\(simUse) ui --udid \(udid)", allowFailure: true)
        guard let session = try await Self.startSession(udid: udid, size: "480x1044") else { return }
        defer { Task { await session.end() } }

        _ = try await CommandRunner.run("\(simUse) tap --udid \(udid) --label 'Tap Count: 0'")
        try await Task.sleep(nanoseconds: 800_000_000)
        let (outline, _) = try await CommandRunner.run("\(simUse) ui --udid \(udid)")
        #expect(Self.tapEcho(outline).count == "1", "the selector tap must land in the resized app: \(outline.prefix(600))")

        await session.end()
    }

    @Test("the first directional gesture after a session starts, and after it ends, reaches the app (R158-03)")
    func firstGestureFollowsSession() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        try await TestHelpers.launchPlaygroundApp(to: "gesture-presets")
        func detected() async throws -> String? {
            let ui = try await TestHelpers.getUIState(simulatorUDID: udid)
            return UIStateParser.findElementContainingLabel(in: ui, containing: "Detected:")?.label
        }
        // Warm "no session" in the daemon, then start one with no `ui` in
        // between: the gesture's own calibration fetch must see the scene.
        _ = try await CommandRunner.run("\(simUse) ui --udid \(udid)", allowFailure: true)
        guard let session = try await Self.startSession(udid: udid) else { return }
        defer { Task { await session.end() } }
        _ = try await CommandRunner.run("\(simUse) gesture scroll-up --duration 0.4 --udid \(udid)")
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(try await detected() == "Detected: 1", "the first gesture in the session must land")

        // End it, again with no `ui` before the gesture.
        await session.end()
        _ = try await CommandRunner.run("\(simUse) gesture scroll-up --duration 0.4 --udid \(udid)")
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(try await detected() == "Detected: 2", "the first gesture after the session must land on the main display")
    }

    @Test("a batch keeps the connection its first routed touch upgraded (S6-001)")
    func batchKeepsUpgradedConnection() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        guard let session = try await Self.startSession(udid: udid) else { return }
        defer { Task { await session.end() } }
        // With Device Hub closed the batch's session starts on Indigo; the
        // routed tap starts dtuhidd and upgrades the connection, and the
        // type step must use the upgraded one, not the disconnected one.
        let (outline, _) = try await CommandRunner.run("\(simUse) ui --udid \(udid)")
        let field = outline.components(separatedBy: "\n").first { $0.contains("TextField") } ?? ""
        let frame = try #require(field.firstMatch(of: #/\((\d+),(\d+) (\d+)x(\d+)\)/#), "no text field: \(outline.prefix(400))")
        let x = Int(frame.1)! + Int(frame.3)! / 2, y = Int(frame.2)! + Int(frame.4)! / 2
        let text = "s6b\(Int.random(in: 100...999))"
        let batch = try await CommandRunner.run(
            // Two keyboard chunks and a second touch (outside the field: a
            // second tap on it soon after the first is a double tap that
            // selects the text).
            "\(simUse) ios batch --udid \(udid) --step 'tap -x \(x) -y \(y)' --step 'type \(text)' --step 'type x' --step 'tap -x 280 -y 700'",
            allowFailure: true, timeout: 60)
        #expect(batch.exitCode == 0, "batch failed: \(batch.output.suffix(400))")
        try await Task.sleep(nanoseconds: 800_000_000)
        let (after, _) = try await CommandRunner.run("\(simUse) ui --udid \(udid)")
        #expect(after.contains("TextField  \"\(text)x\""), "typed text should reach the field: \(after.prefix(500))")
        await session.end()
    }

    @Test("the first gesture after a session is resized uses the new scene size (R161-01)")
    func firstGestureAfterResize() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        try await TestHelpers.launchPlaygroundApp(to: "gesture-presets")
        guard let session = try await Self.startSession(udid: udid, size: "560x1200") else { return }
        defer { Task { await session.end() } }
        // A snapshot of the tall scene; then the session shrinks with no
        // `ui` before the gesture. The old canvas would put the stroke
        // below the new scene.
        _ = try await CommandRunner.run("\(simUse) ui --udid \(udid)", allowFailure: true)
        _ = try await CommandRunner.run(
            "xcrun devicectl device appResize set --device \(udid) --preferred-size 560x667 --quiet --timeout 10")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        _ = try await CommandRunner.run("\(simUse) gesture scroll-up --duration 0.4 --udid \(udid)")
        try await Task.sleep(nanoseconds: 800_000_000)
        let ui = try await TestHelpers.getUIState(simulatorUDID: udid)
        let detected = UIStateParser.findElementContainingLabel(in: ui, containing: "Detected:")?.label
        #expect(detected == "Detected: 1", "the gesture must land in the resized scene, got \(String(describing: detected))")
        await session.end()
    }

    @Test("the first explicit tap after a session starts, and after it ends, reaches the app (S3)")
    func firstExplicitTapFollowsSession() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        // A device-sized snapshot and a warm "no session"; then the
        // session starts with no `ui` before the tap. UI-space coordinates
        // calibrate from the snapshot only when probes confirm it.
        _ = try await CommandRunner.run("\(simUse) ui --udid \(udid)", allowFailure: true)
        guard let session = try await Self.startSession(udid: udid) else { return }
        defer { Task { await session.end() } }
        _ = try await CommandRunner.run("\(simUse) tap --udid \(udid) -x 450 -y 650")
        try await Task.sleep(nanoseconds: 800_000_000)
        let (during, _) = try await CommandRunner.run("\(simUse) ui --udid \(udid)")
        #expect(Self.tapEcho(during).count == "1", "the first tap in the session must land: \(during.prefix(400))")
        #expect(Self.tapEcho(during).location == "(450, 650)")

        // The snapshot is now the session's; end it with no `ui` before
        // the next tap.
        await session.end()
        _ = try await CommandRunner.run("\(simUse) tap --udid \(udid) -x 200 -y 400")
        try await Task.sleep(nanoseconds: 800_000_000)
        let (after, _) = try await CommandRunner.run("\(simUse) ui --udid \(udid)")
        #expect(Self.tapEcho(after).count == "2", "the first tap after the session must land on the main display: \(after.prefix(400))")
    }

    @Test("the first point query after a session starts, and after it ends, describes the app (R158-05)")
    func firstPointQueryFollowsSession() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        func pointQuery() async throws -> (app: String?, display: String?) {
            let (output, _) = try await CommandRunner.run("\(simUse) ui --point 200,300 --json --no-raw --udid \(udid) 2>/dev/null")
            let data = try Self.json(output)["data"] as? [String: Any]
            return (data?["appPackage"] as? String, (data?["display"] as? [String: Any])?["name"] as? String)
        }
        // Warm "no session", then make a point query the first command.
        _ = try await CommandRunner.run("\(simUse) ui --udid \(udid)", allowFailure: true)
        guard let session = try await Self.startSession(udid: udid) else { return }
        defer { Task { await session.end() } }
        let during = try await pointQuery()
        #expect(during.app == "com.cameroncooke.SimUsePlayground", "the point query must describe the resized app, got \(String(describing: during.app))")
        #expect(during.display == "Resizable")

        await session.end()
        let after = try await pointQuery()
        #expect(after.app == "com.cameroncooke.SimUsePlayground")
        #expect(after.display == nil)
    }

    @Test("record-video and stream-video capture the scene during a session; the screenshot formats refuse (S5)")
    func videoCapturesScene() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        guard let session = try await Self.startSession(udid: udid) else { return }
        defer { Task { await session.end() } }
        _ = try await CommandRunner.run("\(simUse) ui --udid \(udid)", allowFailure: true)

        // The recording is the 560x874 scene at 3x, cut from the canvas.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("resize-record-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await RoutedVideo.record(simUse: simUse, udid: udid, output: output, seconds: 2.5)
        let size = try await RoutedVideo.videoSize(output)
        #expect(size == CGSize(width: 1680, height: 2622), "recorded \(String(describing: size))")

        // The native stream reads the same display.
        let bytes = try await RoutedVideo.stream(simUse: simUse, udid: udid, seconds: 2.5)
        #expect(bytes.count > 10_000 && bytes.first == 0x47, "expected an MPEG-TS stream, got \(bytes.count) bytes")

        // The screenshot loop reads the main display only: refused before
        // a single byte reaches stdout.
        let refused = try await CommandRunner.run(
            "\(simUse) stream-video --udid \(udid) --format mjpeg --fps 5", allowFailure: true, timeout: 20
        )
        #expect(refused.exitCode != 0)
        #expect(refused.output.contains("captures only the main display"), "mjpeg must refuse: \(refused.output.prefix(300))")
        #expect(refused.output.contains("--format h264"))

        await session.end()
    }

    @Test("a recording follows the scene the session snapped to (S5-001)")
    func recordingFollowsSnappedScene() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        _ = try? await CommandRunner.run("xcrun simctl terminate \(udid) com.apple.Preferences", allowFailure: true)
        _ = try await CommandRunner.run("xcrun simctl launch \(udid) com.apple.Preferences")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        // Settings' root does not keep a session; its General page does.
        _ = try await CommandRunner.run("\(simUse) tap --id com.apple.settings.general --udid \(udid)", allowFailure: true)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        guard let session = try await Self.startSession(udid: udid) else { return }
        defer { Task { await session.end() } }
        _ = try await CommandRunner.run(
            "xcrun devicectl device appResize set --device \(udid) --preferred-size 402x874 --quiet --timeout 10", allowFailure: true)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // The header shows the scene the app actually took.
        let (outline, _) = try await CommandRunner.run("\(simUse) ui --udid \(udid)")
        let header = outline.components(separatedBy: "\n").first ?? ""
        let size = try #require(header.firstMatch(of: #/  (\d+)x(\d+)  /#), "header: \(header)")
        let sceneWidth = Int(size.1)!, sceneHeight = Int(size.2)!
        func even(_ value: Int) -> Int { (value + 1) / 2 * 2 }

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("snap-record-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await RoutedVideo.record(simUse: simUse, udid: udid, output: output, seconds: 2.5)
        let recorded = try await RoutedVideo.videoSize(output)
        #expect(recorded == CGSize(width: even(sceneWidth * 3), height: even(sceneHeight * 3)),
                "scene \(sceneWidth)x\(sceneHeight) pt, recorded \(String(describing: recorded))")
        await session.end()
    }

    @Test("a short recording whose scene is resized ends with the notice (S5-003)")
    func shortRecordingResizeNotice() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        guard let session = try await Self.startSession(udid: udid) else { return }
        defer { Task { await session.end() } }
        _ = try await CommandRunner.run("\(simUse) ui --udid \(udid)", allowFailure: true)

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("short-record-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        // Well inside the session monitor's 5 s cache window.
        let stderr = try await RoutedVideo.record(simUse: simUse, udid: udid, output: output, seconds: 2.4) {
            _ = try? await CommandRunner.run(
                "xcrun devicectl device appResize set --device \(udid) --preferred-size 560x667 --quiet --timeout 10", allowFailure: true)
        }
        #expect(stderr.contains("was resized while `record-video` ran"), "stderr: \(stderr)")
        #expect(try await RoutedVideo.videoSize(output) == CGSize(width: 1680, height: 2622))
        await session.end()
    }

    @Test("screenshot captures the Resizable display and says so; the main display afterwards")
    func screenshotRedirect() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        guard let session = try await Self.startSession(udid: udid) else { return }
        defer { Task { await session.end() } }
        _ = try await CommandRunner.run("\(simUse) ui --udid \(udid)", allowFailure: true)

        let resized = FileManager.default.temporaryDirectory.appendingPathComponent("resize-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: resized) }
        let (stdout, _) = try await CommandRunner.run("\(simUse) screenshot --udid \(udid) --output \(resized.path) --json")
        let envelope = try Self.json(stdout)
        #expect((envelope["advisory"] as? [String: Any])?["kind"] as? String == "resizable_app_session")
        let resizedData = try Data(contentsOf: resized)
        #expect(resizedData.prefix(4) == Self.pngMagic)
        let resizedSize = try #require(pngSize(resizedData))

        await session.end()
        // Past the 5 s cache window the main display is captured again.
        try await Task.sleep(nanoseconds: 5_500_000_000)

        let native = FileManager.default.temporaryDirectory.appendingPathComponent("native-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: native) }
        let (after, _) = try await CommandRunner.run("\(simUse) screenshot --udid \(udid) --output \(native.path) --json")
        #expect(try Self.json(after)["advisory"] == nil)
        let nativeSize = try #require(pngSize(try Data(contentsOf: native)))
        #expect(resizedSize != nativeSize, "the resized capture (\(resizedSize)) should differ from the main display (\(nativeSize))")
    }

    /// PNG IHDR width/height, enough to tell the two displays apart.
    private func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24 else { return nil }
        func be32(_ offset: Int) -> Int {
            data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        }
        return (be32(16), be32(20))
    }
}
