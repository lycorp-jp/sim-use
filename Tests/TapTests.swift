// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation

@Suite("Tap Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct TapTests {
    @Test("Basic tap registers on screen")
    func basicTap() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Act
        try await TestHelpers.runSimUseCommand("tap -x 200 -y 400", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let tapCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        let tapLocationElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Location:")
        #expect(tapCountElement?.label == "Tap Count: 1", "Tap count should be 1")
        #expect(tapLocationElement?.label == "Tap Location: (200, 400)", "Tap location should be (200, 400)")
    }

    @Test("Tap by AXUniqueId navigates back to home")
    func tapByIDNavigatesBack() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Act
        try await TestHelpers.runSimUseCommand("tap --id BackButton", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let homeMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Touch & Gestures")
        let tapTestMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        #expect(homeMarker != nil)
        #expect(tapTestMarker == nil)
    }
    
    @Test("Tap by AXLabel navigates back to home")
    func tapByLabelNavigatesBack() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")

        // Act
        try await TestHelpers.runSimUseCommand("tap --label 'sim-use Playground'", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Assert
        let uiState = try await TestHelpers.getUIState()
        let homeMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Touch & Gestures")
        let tapTestMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        #expect(homeMarker != nil)
        #expect(tapTestMarker == nil)
    }

    @Test("Tap by --label-contains substring navigates back to home")
    func tapByLabelContainsNavigatesBack() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")

        // The back-nav label is "sim-use Playground"; substring picks it up
        // without baking the whole string into the test, mimicking how
        // dynamic labels are exercised in real apps.
        try await TestHelpers.runSimUseCommand("tap --label-contains 'sim-use'", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let uiState = try await TestHelpers.getUIState()
        let homeMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Touch & Gestures")
        let tapTestMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        #expect(homeMarker != nil)
        #expect(tapTestMarker == nil)
    }

    @Test("Tap by anchored --label-regex navigates back to home")
    func tapByLabelRegexNavigatesBack() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")

        try await TestHelpers.runSimUseCommand("tap --label-regex '^sim-use Playground$'", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let uiState = try await TestHelpers.getUIState()
        let homeMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Touch & Gestures")
        let tapTestMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        #expect(homeMarker != nil)
        #expect(tapTestMarker == nil)
    }

    @Test("Tap --label + --frame absolute band navigates back to home")
    func tapWithAbsoluteFrameBandNavigatesBack() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")

        // The "sim-use Playground" back-nav title sits near the top of
        // the screen; an absolute maxY=200 cap picks it without help
        // from any selector tweak. The tap navigates back to the home
        // screen which we assert on.
        try await TestHelpers.runSimUseCommand(
            "tap --label 'sim-use Playground' --frame maxY=200",
            simulatorUDID: defaultSimulatorUDID
        )
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let uiState = try await TestHelpers.getUIState()
        let homeMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Touch & Gestures")
        #expect(homeMarker != nil)
    }

    @Test("Tap --label + --frame relative band is device-independent")
    func tapWithRelativeFrameBandNavigatesBack() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")

        // Same target, but expressed as "top 30% of the screen" so the
        // command is portable across simulator sizes.
        try await TestHelpers.runSimUseCommand(
            "tap --label 'sim-use Playground' --frame 'minY=0r,maxY=0.3r'",
            simulatorUDID: defaultSimulatorUDID
        )
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let uiState = try await TestHelpers.getUIState()
        let homeMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Touch & Gestures")
        #expect(homeMarker != nil)
    }

    @Test("Tap with overly restrictive --frame fails fast with hint")
    func tapWithFrameOutsideBandFails() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")

        // The back-nav lives near the top, so a band that only covers
        // the bottom 10% must fail. The --json envelope still surfaces
        // the standard hint shape so an agent can self-correct.
        let result = try await TestHelpers.runSimUseCommandAllowFailure(
            "tap --label 'sim-use Playground' --frame minY=0.9r --json",
            simulatorUDID: defaultSimulatorUDID
        )
        #expect(result.exitCode != 0)
        #expect(result.output.contains("\"ok\":false"))
        #expect(result.output.contains("--label"))
    }

    @Test("Tap --label-contains miss surfaces hint in --json envelope")
    func tapLabelContainsMissJSONHint() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")

        let result = try await TestHelpers.runSimUseCommandAllowFailure(
            "tap --label-contains '__no_match_label__' --json",
            simulatorUDID: defaultSimulatorUDID
        )
        #expect(result.exitCode != 0)
        // The envelope is single-line JSON. We assert on the structural keys
        // rather than the exact candidate set so the test is stable across
        // playground tweaks.
        #expect(result.output.contains("\"ok\":false"))
        #expect(result.output.contains("\"hint\""))
        #expect(result.output.contains("--label-contains"))
        #expect(result.output.contains("__no_match_label__"))
    }
    
    @Test("Multiple taps register correct count")
    func multipleTaps() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        let tapCount = 3
        
        // Act
        for i in 1...tapCount {
            try await TestHelpers.runSimUseCommand("tap -x \(100 + i * 50) -y \(300 + i * 20)", simulatorUDID: defaultSimulatorUDID)
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let tapCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        #expect(tapCountElement?.label == "Tap Count: \(tapCount)", "Tap count should be \(tapCount)")
    }
    
    @Test("Tap with pre and post delays")
    func tapWithDelays() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Act
        let startTime = Date()
        try await TestHelpers.runSimUseCommand("tap -x 200 -y 300 --pre-delay 1.0 --post-delay 1.0", simulatorUDID: defaultSimulatorUDID)
        let endTime = Date()
        
        // Assert
        let duration = endTime.timeIntervalSince(startTime)
        #expect(duration >= 2.0, "Command should take at least 2 seconds with delays")
        
        let uiState = try await TestHelpers.getUIState()
        let tapCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        #expect(tapCountElement?.label == "Tap Count: 1", "Tap should still register with delays")
    }
    
    @Test("At least one tap registers at screen edges")
    func tapAtEdgesRegistersAtLeastOne() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Test corners
        let corners = [
            (x: 10, y: 100),      // Top-left
            (x: 380, y: 100),     // Top-right
            (x: 10, y: 800),      // Bottom-left
            (x: 380, y: 800)      // Bottom-right
        ]
        
        // Act
        for corner in corners {
            try await TestHelpers.runSimUseCommand("tap -x \(corner.x) -y \(corner.y)", simulatorUDID: defaultSimulatorUDID)
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        // Assert - edge taps can be flaky, require at least one successful registration
        let uiState = try await TestHelpers.getUIState()
        let tapCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        let tapCount = Int((tapCountElement?.label ?? "").replacingOccurrences(of: "Tap Count: ", with: "")) ?? 0
        #expect(tapCount >= 1, "At least one edge tap should register despite simulator edge flakiness")
    }
}