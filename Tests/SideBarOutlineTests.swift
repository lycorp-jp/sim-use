// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

// Live coverage for the outline's side-bar regions
// (docs/ai/010-display-routing, S4). On an iPhone Duo with a Playground
// built against the iOS 27.1 SDK, the cover display shows the navigation
// and tab chrome in a vertical bar: the outline lists it as `[Trailing …]`
// (portrait) or `[Leading …]` (landscape-right), and `@N` taps from that
// region land. On any other simulator, or with an older SDK build, the
// same screen keeps its horizontal bars and no side region appears.

@Suite("Outline side bars", .serialized, .enabled(if: isE2EEnabled))
struct SideBarOutlineTests {
    private static func outline(udid: String) async throws -> String {
        try await CommandRunner.run("\(try TestHelpers.getSimUsePath()) ui --udid \(udid)").output
    }

    /// The `@N` alias on the line of `region` whose text contains `needle`.
    private static func alias(of needle: String, in region: String, outline: String) -> String? {
        var inRegion = false
        for line in outline.components(separatedBy: "\n") {
            if line.hasPrefix("[") { inRegion = line.hasPrefix("[\(region)") }
            guard inRegion, line.contains(needle) else { continue }
            return line.split(separator: " ").first { $0.hasPrefix("@") }.map(String.init)
        }
        return nil
    }

    private static func lastAction(udid: String) async throws -> String? {
        let text = try await outline(udid: udid)
        guard let line = text.components(separatedBy: "\n").first(where: { $0.contains("\"Last action: ") }),
              let start = line.range(of: "\"Last action: ")
        else { return nil }
        return "Last action: " + line[start.upperBound...].prefix { $0 != "\"" }
    }

    private static func isMultiDisplay(udid: String) async -> Bool {
        let result = try? await TestHelpers.runSimUseCommandAllowFailure("ios fold closed", simulatorUDID: udid)
        return result?.exitCode == 0
    }

    @Test("the bar is its own region and its aliases land", arguments: [
        ("portrait", "Trailing"),
        ("landscape-right", "Leading"),
    ])
    func barRegion(orientation: String, region: String) async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let multiDisplay = await Self.isMultiDisplay(udid: udid)
        try await TestHelpers.launchPlaygroundApp(to: "chrome-test")
        _ = try await TestHelpers.runSimUseCommandAllowFailure("ios rotate \(orientation)", simulatorUDID: udid)
        // Let the rotation animation finish before the outline is read; a
        // mid-animation snapshot once sent both alias taps astray.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        do {
            let text = try await Self.outline(udid: udid)
            // `make e2e-ios-duo` with an iOS 27.1+ SDK Playground sets this.
            let expectBar = ProcessInfo.processInfo.environment["SIM_USE_E2E_EXPECT_SIDE_BAR"] == "1"
            #expect(!expectBar || !multiDisplay || text.contains("[\(region)"), "expected a \(region) region: \(text)")
            guard multiDisplay, text.contains("[\(region)") else {
                // A single display, or an SDK that keeps horizontal bars.
                #expect(!text.contains("[Leading") && !text.contains("[Trailing"), "unexpected side region: \(text)")
                _ = try? await TestHelpers.runSimUseCommandAllowFailure("ios rotate portrait", simulatorUDID: udid)
                return
            }
            #expect(Self.alias(of: "#BackButton", in: region, outline: text) != nil, "BackButton in the bar: \(text)")

            let search = try #require(Self.alias(of: "\"Search\"", in: region, outline: text), "Search tab in the bar: \(text)")
            try await TestHelpers.runSimUseCommand("tap \(search)", simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 600_000_000)
            #expect(try await Self.lastAction(udid: udid) == "Last action: tab-search")

            let refreshed = try await Self.outline(udid: udid)
            let add = try #require(Self.alias(of: "\"Add\"", in: region, outline: refreshed), "Add in the bar: \(refreshed)")
            try await TestHelpers.runSimUseCommand("tap \(add)", simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 600_000_000)
            #expect(try await Self.lastAction(udid: udid) == "Last action: add")

            // The back button has no label on the cover; its id finds it.
            try await TestHelpers.runSimUseCommand("tap --id BackButton", simulatorUDID: udid)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let home = try await Self.outline(udid: udid)
            #expect(home.contains("Tap Test"), "back on the menu: \(home.prefix(300))")
        } catch {
            _ = try? await TestHelpers.runSimUseCommandAllowFailure("ios rotate portrait", simulatorUDID: udid)
            throw error
        }
        _ = try? await TestHelpers.runSimUseCommandAllowFailure("ios rotate portrait", simulatorUDID: udid)
    }
}
