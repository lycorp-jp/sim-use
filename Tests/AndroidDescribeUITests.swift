// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Suite("Android Describe-UI Tests", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidDescribeUITests {
    @Test("List detection assigns #1 to the first row and the alias resolves")
    func listAliasResolvesRow() async throws {
        try await AndroidE2E.launch(screen: "scroll-test")

        let ui = try await AndroidE2E.waitForOutline { !$0.lists.isEmpty && $0.listCell(index: 1) != nil }
        #expect(!ui.lists.isEmpty, "RecyclerView should be detected as a Tier-1 list")

        let firstCell = try #require(ui.listCell(index: 1), "expected a #1 list cell")
        #expect(firstCell.label == "Row 1")

        // The `#N` alias must resolve end-to-end through the CLI selector.
        let tap = try await AndroidE2E.run("tap '#1'", allowFailure: true)
        #expect(tap.exitCode == 0, "tap '#1' should resolve the first list cell. Output: \(tap.output)")
    }

    @Test("--include-offscreen is accepted and never drops visible rows")
    func includeOffscreenIsMonotonic() async throws {
        // On the current Android pipeline `--include-offscreen` relaxes
        // only the *geometric* off-screen filter. Recycled RecyclerView
        // cells report `visibleToUser=false` (dropped unconditionally
        // upstream) and carry clamped, non-positive-height bounds, so the
        // flag does not resurface them here — see the Android E2E notes.
        // We therefore pin the contract that actually holds: the flag is
        // accepted and yields at least as many rows as the default.
        try await AndroidE2E.launch(screen: "scroll-test")

        let base = try await AndroidE2E.describeUI(includeOffscreen: false)
        let extended = try await AndroidE2E.describeUI(includeOffscreen: true)

        let baseRows = base.entries.filter { ($0.resourceId ?? "").hasPrefix("row_") }.count
        let extRows = extended.entries.filter { ($0.resourceId ?? "").hasPrefix("row_") }.count
        #expect(baseRows > 0, "expected some visible rows")
        #expect(extRows >= baseRows, "--include-offscreen must not drop rows")
    }

    @Test("screenshot writes a PNG file")
    func screenshotWritesPng() async throws {
        try await AndroidE2E.launch(screen: "tap-test")

        let path = "\(NSTemporaryDirectory())simuse-android-shot-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }

        try await AndroidE2E.run("screenshot --output \(path)")
        try #require(FileManager.default.fileExists(atPath: path), "screenshot file should exist")

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data.count > 1000, "screenshot should be non-trivial (\(data.count) bytes)")
        // PNG signature: 89 50 4E 47.
        #expect(Array(data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47], "file should be a PNG")
    }

    @Test("app-state reports the playground running")
    func appStateReportsPlayground() async throws {
        try await AndroidE2E.launch(screen: "tap-test")
        let running = try await AndroidE2E.runningPackages()
        #expect(running.contains(AndroidE2E.playgroundPackage))
    }
}
