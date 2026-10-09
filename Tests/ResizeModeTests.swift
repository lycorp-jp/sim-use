// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

// Live coverage for the Xcode 27 Resize Mode stop-gap (issue #143). Needs
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
            process.waitUntilExit()
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

    @Test("ui carries the resizable_app_session advisory and keeps the tree to the app's own process")
    func describeUIAdvisory() async throws {
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
        let advisory = try #require(envelope["advisory"] as? [String: Any])
        #expect(advisory["kind"] as? String == "resizable_app_session")
        #expect((advisory["message"] as? String ?? "").contains("'Resizable' display"))

        let data = try #require(envelope["data"] as? [String: Any])
        let screen = try #require(data["screen"] as? [String: Any])
        #expect(screen["width"] as? Int == 560, "scene width should be the requested 560, got \(String(describing: screen["width"]))")
        #expect(data["orientation"] as? String == "portrait")

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

    @Test("touch verbs refuse with the session error; type still reaches the app")
    func touchRefusedKeyboardWorks() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        // The text-input screen focuses its field on launch (TypeTests
        // relies on the same), so nothing needs tapping before the session.
        try await TestHelpers.launchPlaygroundApp(to: "text-input")

        guard let session = try await Self.startSession(udid: udid) else { return }
        defer { Task { await session.end() } }

        // The daemon caches the devicectl answer for 5 s and the launch
        // helper's describe-ui may have cached "no session" moments ago.
        // A `ui` here sees the 560-wide root, which bypasses that cache,
        // so the touch verbs below meet an up-to-date gate.
        _ = try await CommandRunner.run("\(simUse) ui --udid \(udid)", allowFailure: true)

        let tap = try await CommandRunner.run("\(simUse) tap --udid \(udid) -x 100 -y 300 --json", allowFailure: true)
        #expect(tap.exitCode != 0)
        let tapEnvelope = try Self.json(tap.output)
        #expect(tapEnvelope["ok"] as? Bool == false)
        #expect((tapEnvelope["error"] as? String ?? "").contains("resizable app session"))
        #expect((tapEnvelope["hint"] as? String ?? "").contains("appResize start"))

        let swipe = try await CommandRunner.run("\(simUse) swipe --udid \(udid) --start-x 100 --start-y 600 --end-x 100 --end-y 200", allowFailure: true)
        #expect(swipe.exitCode != 0)
        #expect(swipe.output.contains("this swipe would report success and deliver nothing"))

        let batchFile = FileManager.default.temporaryDirectory.appendingPathComponent("resize-batch-\(UUID().uuidString).txt")
        try "type x\ntap @1\n".write(to: batchFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: batchFile) }
        let batch = try await CommandRunner.run("\(simUse) ios batch --udid \(udid) --file \(batchFile.path)", allowFailure: true)
        #expect(batch.exitCode != 0)
        #expect(batch.output.contains("this batch would report success"))

        // `paste --via-menu` is a touch path (long-press + menu taps) and
        // is refused before the pasteboard is written — for a coordinate
        // target and for an id target alike (R150-01). Cmd+V paste is
        // keyboard HID and stays available.
        let pasteXY = try await CommandRunner.run(
            "\(simUse) paste --udid \(udid) --via-menu --target-x 100 --target-y 300 --menu-timeout 0.5 --json menu-xy", allowFailure: true
        )
        #expect(pasteXY.exitCode != 0)
        let pasteXYEnvelope = try Self.json(pasteXY.output)
        #expect((pasteXYEnvelope["error"] as? String ?? "").contains("this paste --via-menu would report success"))
        let pasteID = try await CommandRunner.run(
            "\(simUse) paste --udid \(udid) --via-menu --target-id text-input-screen --menu-timeout 0.5 menu-id", allowFailure: true
        )
        #expect(pasteID.exitCode != 0)
        #expect(pasteID.output.contains("this paste --via-menu would report success"))
        let pasteKeyboard = try await CommandRunner.run("\(simUse) paste --udid \(udid) kbd", allowFailure: true)
        #expect(pasteKeyboard.exitCode == 0, "Cmd+V paste must not be refused: \(pasteKeyboard.output.prefix(300))")
        #expect(!pasteKeyboard.output.contains("resizable app session"))

        _ = try await CommandRunner.run("\(simUse) type --udid \(udid) 'resized'")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let (outline, _) = try await CommandRunner.run("\(simUse) ui --udid \(udid)")
        #expect(outline.contains("resized"), "typed text should reach the resized app; outline:\n\(outline.prefix(600))")

        await session.end()
    }

    @Test("a batch started inside the stale no-session cache window is still refused at its first touch step (R150-02)")
    func batchInsideStaleCacheWindowIsRefused() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        // Warm the daemon's cache with "no session" right before the
        // session starts — the shape the reviewer reproduced live. The
        // pre-scan then sees a stale inactive answer; the selector step's
        // tree fetch supplies the 560-wide evidence, and the per-step
        // gate must refuse before the first touch is dispatched.
        _ = try await CommandRunner.run("\(simUse) ui --udid \(udid)", allowFailure: true)
        guard let session = try await Self.startSession(udid: udid) else { return }
        defer { Task { await session.end() } }

        let batchFile = FileManager.default.temporaryDirectory.appendingPathComponent("resize-stale-batch-\(UUID().uuidString).txt")
        try "tap --label 'Tap Count: 0'\nsleep 1\ntap -x 100 -y 300\n".write(to: batchFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: batchFile) }
        let batch = try await CommandRunner.run("\(simUse) ios batch --udid \(udid) --file \(batchFile.path) --json", allowFailure: true)
        #expect(batch.exitCode != 0, "batch must not report success inside a session: \(batch.output.prefix(400))")
        let envelope = try Self.json(batch.output)
        #expect(envelope["ok"] as? Bool == false)
        #expect((envelope["error"] as? String ?? "").contains("this batch would report success and deliver nothing"))
        #expect((envelope["hint"] as? String ?? "").contains("appResize start"))

        // Nothing reached the app.
        let (outline, _) = try await CommandRunner.run("\(simUse) ui --udid \(udid)")
        #expect(outline.contains("Tap Count: 0"), "no touch may have landed; outline:\n\(outline.prefix(600))")

        await session.end()
    }

    @Test("a selector tap inside the stale cache window is refused for a scene proportional to the device (R150-05)")
    func selectorTapInsideStaleWindowProportionalScene() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        // Warm "no session", then start a session whose scene is the
        // device's 402x874 scaled uniformly (~1.194x). The reviewer slipped
        // a tap past a proportional-size exclusion with exactly this; the
        // selector fetch must now count 480x1044 as evidence and refuse.
        _ = try await CommandRunner.run("\(simUse) ui --udid \(udid)", allowFailure: true)
        guard let session = try await Self.startSession(udid: udid, size: "480x1044") else { return }
        defer { Task { await session.end() } }

        let tap = try await CommandRunner.run("\(simUse) tap --udid \(udid) --label 'Tap Count: 0' --json", allowFailure: true)
        #expect(tap.exitCode != 0, "selector tap must be refused inside the window: \(tap.output.prefix(400))")
        let envelope = try Self.json(tap.output)
        #expect(envelope["ok"] as? Bool == false)
        #expect((envelope["error"] as? String ?? "").contains("resizable app session"))

        let (outline, _) = try await CommandRunner.run("\(simUse) ui --udid \(udid)")
        #expect(outline.contains("[i] A resizable app session"))
        #expect(outline.contains("Tap Count: 0"))

        await session.end()
    }

    @Test("record-video and stream-video are refused during a session, before producing output (R150-06)")
    func videoCaptureRefused() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUse = try TestHelpers.getSimUsePath()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        guard let session = try await Self.startSession(udid: udid) else { return }
        defer { Task { await session.end() } }
        _ = try await CommandRunner.run("\(simUse) ui --udid \(udid)", allowFailure: true)

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("resize-record-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let record = try await CommandRunner.run(
            "\(simUse) record-video --udid \(udid) --fps 5 --output \(output.path) --json", allowFailure: true, timeout: 20
        )
        #expect(record.exitCode != 0)
        let recordEnvelope = try Self.json(record.output)
        #expect((recordEnvelope["error"] as? String ?? "").contains("`record-video` captures only the main display"))
        #expect((recordEnvelope["hint"] as? String ?? "").contains("recordVideo --display="))
        #expect(!FileManager.default.fileExists(atPath: output.path), "no output file may be created")

        // stream-video rejects --json by design (stdout carries the video
        // bytes), so the refusal is the plain stderr form; it exits before
        // the stream starts, so no pipe or timeout dance is needed.
        let stream = try await CommandRunner.run(
            "\(simUse) stream-video --udid \(udid) --format h264 --fps 5", allowFailure: true, timeout: 20
        )
        #expect(stream.exitCode != 0)
        #expect(stream.output.contains("`stream-video` captures only the main display"), "stream must refuse before emitting video: \(stream.output.prefix(300))")
        #expect(stream.output.contains("recordVideo --display="))

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
