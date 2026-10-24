// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import AndroidBackend
import ArgumentParser
import Foundation
import SimUseCore
import Testing

// Pins the contract between top-level `Screenshot`,
// `IOSSimScreenshotCommand`, and `AndroidScreenshotCommand`.
@Suite("Screenshot forwarder")
@MainActor
struct ScreenshotForwarderTests {

    // MARK: - Symmetric forwarder contract

    @Test("AndroidScreenshotCommand.performScreenshot is callable with the forwarder's argument shape")
    func androidScreenshotPerformContract() {
        let _: (
            String,
            AndroidDeviceController
        ) throws -> Data = AndroidScreenshotCommand.performScreenshot
    }

    // MARK: - Flag-surface parity

    @Test("ArgumentParser parses both top-level Screenshot and IOSSimScreenshotCommand with same flags")
    func flagSurfaceParses() throws {
        let argv = [
            "--output", "/tmp/shot.png",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
            "--json",
        ]
        let topLevel = try Screenshot.parse(argv)
        let subCmd = try IOSSimScreenshotCommand.parse(argv)

        #expect(topLevel.output == "/tmp/shot.png")
        #expect(subCmd.output == "/tmp/shot.png")
        #expect(topLevel.jsonOutput)
        #expect(subCmd.jsonOutput)
    }

    // Captures used to bypass the daemon on the grounds that a spawn costs
    // more than it saves. Every UDID-scoped verb already keeps the daemon
    // warm, and there a capture skips rebuilding the simulator set and the
    // display-routing probes, so iOS simulator captures go through it;
    // Android and physical iOS stay in-process.
    @Test("iOS simulator captures use the daemon; Android and physical iOS stay in-process")
    func daemonRoutingByPlatform() throws {
        var ios = try Screenshot.parse(["--device", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0"])
        try ios.resolveDeferredArguments()
        #expect(ios.daemonBypass == false)
        #expect(try IOSSimScreenshotCommand.parse([]).daemonBypass == false)
        var android = try Screenshot.parse(["--device", "emulator-5556"])
        try android.resolveDeferredArguments()
        #expect(android.daemonBypass)
        var physical = try Screenshot.parse([])
        physical.device.resolved = "00008110-001A2B3C4D5E801E"
        #expect(physical.daemonBypass)
    }

    @Test("Captures skip the daemon's per-command liveness probe")
    func skipsLivenessProbe() throws {
        #expect(try Screenshot.parse([]).managesLivenessState)
        #expect(try IOSSimScreenshotCommand.parse([]).managesLivenessState)
    }

    @Test("The daemon gets an absolute --output anchored at the caller's directory")
    func daemonOutputAnchoring() {
        let base = ["screenshot", "--device", "X", "--json"]
        func args(_ output: String?, _ tail: [String] = []) -> [String] {
            IOSSimScreenshotCommand.daemonArguments(from: base + tail, output: output, cwd: "/work/dir")
        }
        #expect(args(nil) == base + ["--output", "/work/dir"])
        #expect(args("shot.png", ["--output", "shot.png"]) == base + ["--output", "/work/dir/shot.png"])
        #expect(args("sub/shot.png", ["--output=sub/shot.png"]) == base + ["--output", "/work/dir/sub/shot.png"])
        #expect(args("/abs/shot.png", ["--output", "/abs/shot.png"]) == base + ["--output", "/abs/shot.png"])
        #expect(args("~/shot.png", ["--output", "~/shot.png"]) == base + ["--output", NSHomeDirectory() + "/shot.png"])
    }

    // MARK: - Output path resolution

    @Test("Default iOS output filename embeds the simulator name")
    func defaultIOSOutputName() throws {
        let url = try IOSSimScreenshotCommand.prepareOutputURL(
            output: nil,
            simulatorName: "iPhone 17 Pro"
        )
        #expect(url.lastPathComponent.hasPrefix("Simulator Screenshot - iPhone 17 Pro - "))
        #expect(url.pathExtension == "png")
    }

    @Test("A simulator name containing path separators stays a single filename component")
    func slashedSimulatorNameStaysSingleComponent() throws {
        let url = try IOSSimScreenshotCommand.prepareOutputURL(
            output: nil,
            simulatorName: "My iPhone/Work"
        )
        #expect(url.deletingLastPathComponent().path == FileManager.default.currentDirectoryPath)
        #expect(url.lastPathComponent.hasPrefix("Simulator Screenshot - My iPhone-Work - "))
    }

    @Test("A traversal-shaped simulator name cannot escape the current directory")
    func traversalSimulatorNameResolvesIntoCwd() throws {
        let url = try IOSSimScreenshotCommand.prepareOutputURL(
            output: nil,
            simulatorName: "../../evil"
        )
        #expect(url.deletingLastPathComponent().path == FileManager.default.currentDirectoryPath)
        #expect(!url.lastPathComponent.contains("/"))
    }

    @Test("Tilde-prefixed --output expands the home directory")
    func tildeExpansion() throws {
        let url = try IOSSimScreenshotCommand.prepareOutputURL(
            output: "~/sim-use-tests/shot.png",
            simulatorName: "iPhone 17 Pro"
        )
        #expect(url.path.hasPrefix(NSHomeDirectory()))
        #expect(url.lastPathComponent == "shot.png")
        // Best-effort cleanup so successive runs stay idempotent.
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}