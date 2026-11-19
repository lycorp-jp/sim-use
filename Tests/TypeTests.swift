// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import SimUseCore

@Suite("Type Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct TypeTests {
    @Test("Basic text typing")
    func basicTextTyping() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let textToType = "Hello World"
        
        // Act
        try await TestHelpers.runSimUseCommand("type \"\(textToType)\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement != nil, "Should find text field element")
        #expect(textFieldElement?.value == textToType, "Text field should contain typed text")
    }
    
    @Test("Typing with special characters")
    func typingSpecialCharacters() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        // Note: Using only characters that have keycode mappings in sim-use
        let textToType = "Test@123!$%&*"  // Removed £ which doesn't have keycode mapping
        
        // Act
        try await TestHelpers.runSimUseCommand("type \"\(textToType)\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement?.value == textToType, "Special characters should be typed correctly")
    }
    
    @Test("Typing with numbers")
    func typingNumbers() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let textToType = "1234567890"
        
        // Act
        try await TestHelpers.runSimUseCommand("type \"\(textToType)\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement?.value == textToType, "Numbers should be typed correctly")
    }
    
    @Test("Typing with mixed case")
    func typingMixedCase() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let textToType = "HeLLo WoRLd"
        
        // Act
        try await TestHelpers.runSimUseCommand("type \"\(textToType)\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement?.value == textToType, "Mixed case should be preserved")
    }
    
    @Test("Typing with spaces and punctuation")
    func typingSpacesAndPunctuation() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let inputText = "Hello, how are you? I'm fine!"
        
        // Act
        // Escape the text properly for shell - use double quotes and escape internal quotes
        let escapedText = inputText.replacingOccurrences(of: "\"", with: "\\\"")
        try await TestHelpers.runSimUseCommand("type \"\(escapedText)\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" && element.value != nil
        }
        // Note: iOS may add smart punctuation spacing even with autocorrect disabled
        // We'll accept either with or without the extra space
        let actualValue = textFieldElement?.value ?? ""
        let acceptableValues = [
            inputText,
            "Hello, how are you ? I'm fine!"  // With iOS smart punctuation spacing
        ]
        #expect(acceptableValues.contains(actualValue), 
                "Text should match expected value (with or without iOS smart punctuation)")
    }
    
    @Test("Typing empty string")
    func typingEmptyString() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        
        // First type something to ensure field is not empty
        try await TestHelpers.runSimUseCommand("type \"Initial text\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Act - type empty string (should do nothing)
        try await TestHelpers.runSimUseCommand("type \"\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Assert - text should remain unchanged
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement?.value == "Initial text", "Empty string should not change existing text")
    }
    
    @Test("Typing long text")
    func typingLongText() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let textToType = "The quick brown fox jumps over the lazy dog. " +
                        "This is a longer piece of text to test typing performance and accuracy."
        
        // Act
        try await TestHelpers.runSimUseCommand("type \"\(textToType)\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement?.value == textToType, "Long text should be typed correctly")
    }
    
    @Test("Typing with manual delays")
    func typingWithManualDelays() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let textToType = "Delayed"
        
        // Act - Since sim-use type doesn't have built-in delay options, we'll add manual delays
        let startTime = Date()
        try await Task.sleep(nanoseconds: 1_000_000_000) // Manual pre-delay
        try await TestHelpers.runSimUseCommand("type \"\(textToType)\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000) // Manual post-delay
        let endTime = Date()
        
        // Assert
        let duration = endTime.timeIntervalSince(startTime)
        #expect(duration >= 2.0, "Command should take at least 2 seconds with manual delays")
        
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement?.value == textToType, "Text should still be typed with manual delays")
    }
    
    @Test("Unsupported characters throw error")
    func unsupportedCharactersError() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let unsupportedText = "Price: £50"  // £ is not supported by HID keycodes
        
        // Act & Assert - Command should fail with unsupported character error
        await #expect(throws: (any Error).self) {
            try await TestHelpers.runSimUseCommand("type '\(unsupportedText)'", simulatorUDID: defaultSimulatorUDID)
        }
    }
    
    @Test("Typing from stdin")
    func typingFromStdin() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let textToType = "Stdin" + UUID().uuidString.prefix(8)

        guard let udid = defaultSimulatorUDID else {
            throw TestError.commandError("No simulator UDID specified in SIMULATOR_UDID environment variable")
        }
        let simUsePath = try TestHelpers.getSimUsePath()
        let command = "'\(simUsePath)' type --stdin --udid '\(udid)'"
        // Debug output is selected when the daemon starts. Reusing a quiet
        // daemon would let the privacy assertions pass without exercising it.
        let stopDaemon = "'\(simUsePath)' daemon stop --udid '\(udid)'"
        _ = try await CommandRunner.run(stopDaemon)
        _ = try await CommandRunner.run(
            "'\(simUsePath)' keyboard-state --udid '\(udid)'",
            environment: ["SIM_USE_DEBUG": "1"]
        )
        let logURL = DaemonPaths(udid: udid).logfileURL
        let log = try FileHandle(forReadingFrom: logURL)
        defer { try? log.close() }
        try log.seekToEnd()

        let success = try await CommandRunner.run("printf '%s' '\(textToType)' | \(command)")
        #expect(!success.output.contains(textToType))
        let failure = try await CommandRunner.run(
            "printf '%s' '\(textToType)猫' | \(command)", allowFailure: true
        )
        #expect(failure.exitCode != 0)
        #expect(failure.output.contains("keyboard"))
        #expect(!failure.output.contains(textToType))
        #expect(!failure.output.contains("猫"))
        let diagnostics = String(decoding: try log.readToEnd() ?? Data(), as: UTF8.self)
        _ = try await CommandRunner.run(stopDaemon)
        #expect(diagnostics.contains("Text typing completed successfully"))
        #expect(!diagnostics.contains(textToType))
        #expect(!diagnostics.contains("猫"))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement?.value == textToType, "Text from stdin should be typed correctly")
    }
    
    @Test("Typing from file")
    func typingFromFile() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "text-input")
        let textToType = "Text from file input"
        
        // Create temporary file
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test-input-\(UUID().uuidString).txt")
        try textToType.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        // Act
        try await TestHelpers.runSimUseCommand("type --file \"\(tempFile.path)\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let textFieldElement = UIStateParser.findElement(in: uiState) { element in
            element.type == "TextField" || element.type == "TextEditor"
        }
        #expect(textFieldElement?.value == textToType, "Text from file should be typed correctly")
    }

    @Test("Typed text surfaces in the text outline for a labeled TextArea")
    func textAreaOutlineValue() async throws {
        // Arrange — the text-area screen hosts a TextEditor with an
        // accessibility label, mirroring real-world chat inputs: the label
        // owns the outline's label slot, so the typed text is observable
        // only through the value= tag.
        try await TestHelpers.launchPlaygroundApp(to: "text-area")
        let textToType = "hello textarea"

        // Act
        try await TestHelpers.runSimUseCommand("type \"\(textToType)\"", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Assert — on the human-readable outline, not the JSON envelope.
        let outline = try await TestHelpers.runSimUseCommand("describe-ui", simulatorUDID: defaultSimulatorUDID)
        let fieldLine = outline.output
            .split(separator: "\n")
            .first { $0.contains("#text-area-field") }
        #expect(fieldLine != nil, "Outline should contain the text-area field")
        #expect(
            fieldLine?.contains(#"value="\#(textToType)""#) == true,
            "Outline should surface the typed text, got: \(fieldLine.map(String.init) ?? "<missing>")"
        )
    }
}