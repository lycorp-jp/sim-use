// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

// E2E for the issue #64 empty-shell retry: a system document picker is
// hosted by a remote process, so the frontmost (Safari) tree collapses
// to a bare AXApplication and pre-fix `describe-ui` went blind. The fix
// refetches with upstream's remote-content discovery and flags the
// result with a `remote_content_recovery` advisory.
//
// The scene is fully scriptable: a local page with a file input, opened
// in Safari, drives the cross-process picker via two taps. No fixture
// app and no rotation required.

@Suite("RemoteContentRecoveryTests", .serialized, .enabled(if: isE2EEnabled))
struct RemoteContentRecoveryTests {

    private static let port = 8899

    // The browser labels a bare file input in the simulator's language, and
    // the picker it opens is system UI with no AXUniqueId to match on. An
    // aria-label the fixture owns keeps the one selector this scene needs
    // independent of the simulator's locale.
    private static let fileInputLabel = "e2e-file-input"

    private func writeUploadPage() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sim-use-remote-content-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let html = """
        <html><body style="font-size:40px">
        <h1>Upload test</h1>
        <input type="file" accept="text/plain" aria-label="\(Self.fileInputLabel)" style="font-size:40px">
        </body></html>
        """
        try html.write(to: dir.appendingPathComponent("upload.html"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test("describe-ui recovers the cross-process document picker")
    func describeUIRecoversPicker() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        // A per-UDID daemon spawned by an older binary survives across
        // builds and would serve the pre-fix fetch path; restart it so
        // this scene exercises the build under test.
        _ = try? await TestHelpers.runSimUseCommandAllowFailure("daemon stop --device \(udid)")

        // The scene's second tap resolves against an action sheet whose
        // symmetric, sparse layout gives orientation calibration nothing
        // to discriminate with — on a rotated simulator an ambiguous
        // guess can map the tap one row off (into the camera option).
        // Require portrait up front so a leftover rotation fails loudly
        // here instead of as a misleading assertion miss at the end.
        let pre = try await TestHelpers.runSimUseCommand(
            "describe-ui --json --no-raw", simulatorUDID: udid)
        if let env = try? JSONSerialization.jsonObject(with: Data(pre.output.utf8)) as? [String: Any],
           let data = env["data"] as? [String: Any],
           let orientation = data["orientation"] as? String {
            try #require(
                orientation == "portrait",
                "RemoteContentRecoveryTests requires a portrait simulator (found \(orientation)); rotate the Simulator back to portrait."
            )
        }
        let dir = try writeUploadPage()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", String(Self.port), "--directory", dir.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            server.terminate()
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            cleanup.arguments = ["simctl", "terminate", udid, "com.apple.mobilesafari"]
            if (try? cleanup.run()) != nil {
                cleanup.waitUntilExit()
            }
        }

        _ = try await CommandRunner.run(
            "xcrun simctl openurl \(udid) http://localhost:\(Self.port)/upload.html")

        // One tap is enough: `accept` rules out the photo sources, so iOS
        // skips the action sheet it would otherwise put between the input
        // and the document picker. The picker is hosted by a remote
        // process either way, which is the state this scene exists to
        // reach.
        _ = try await TestHelpers.runSimUseCommand(
            "tap --label '\(Self.fileInputLabel)' --wait-timeout 10", simulatorUDID: udid)

        // Let the remote picker sheet settle.
        try await Task.sleep(nanoseconds: 4_000_000_000)

        let result = try await TestHelpers.runSimUseCommand(
            "describe-ui --json --no-raw", simulatorUDID: udid)

        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
            "describe-ui --json did not return a JSON object: \(result.output.prefix(300))"
        )
        let data = try #require(envelope["data"] as? [String: Any])
        let entries = try #require(data["entries"] as? [[String: Any]])

        // Pre-fix this scene produced zero entries; the recovered picker
        // must surface real, framed elements and say how it got them.
        #expect(entries.count >= 3, "picker should surface elements; got \(entries.count)")
        let advisory = try #require(
            envelope["advisory"] as? [String: Any],
            "expected a remote_content_recovery advisory on the envelope"
        )
        #expect(advisory["kind"] as? String == "remote_content_recovery")
    }
}
