// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Darwin
import Foundation
import Testing
@testable import SimUseCore

// MARK: - Shared daemon command-parser gate

/// `DaemonDispatch.commandParser` is process-global mutable state. Every
/// suite that installs a fake parser and then `await`s (spinning up a
/// real `DaemonServer`, driving a slow dispatch, running a full
/// `invoke`) yields the main actor while holding it, so two such suites
/// running concurrently clobber each other's parser — one sees the
/// other's fake, or a `nil` from a sibling's `defer`. This actor
/// serialises the whole set-use-restore window across suites regardless
/// of swift-testing's parallelism. `.serialized` only orders tests
/// within one suite, which is not enough here.
actor CommandParserGate {
    static let shared = CommandParserGate()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Install `parser` as `DaemonDispatch.commandParser` for the duration of
/// `body`, holding the shared gate so no other suite's parser window
/// overlaps. Restores the previous parser and releases the gate on the
/// way out, including when `body` throws.
@MainActor
func withExclusiveCommandParser(
    _ parser: (@MainActor ([String]) throws -> ParsableCommand)?,
    body: () async throws -> Void
) async throws {
    await CommandParserGate.shared.acquire()
    let saved = DaemonDispatch.commandParser
    DaemonDispatch.commandParser = parser
    do {
        try await body()
    } catch {
        DaemonDispatch.commandParser = saved
        await CommandParserGate.shared.release()
        throw error
    }
    DaemonDispatch.commandParser = saved
    await CommandParserGate.shared.release()
}

// MARK: - Command Execution

let defaultSimulatorUDID = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
let isE2EEnabled = {
    let raw = ProcessInfo.processInfo.environment["SIM_USE_E2E"]?.lowercased() ?? ""
    return raw == "1" || raw == "true" || raw == "yes"
}()

struct ShellOutput {
    let output: String
    let exitCode: Int32
}

struct CommandRunner {
    static func run(
        _ command: String,
        environment: [String: String]? = nil,
        allowFailure: Bool = false,
        timeout: TimeInterval = 30
    ) async throws -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]

        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let stdoutReadTask = Task {
            try outputPipe.fileHandleForReading.readToEnd() ?? Data()
        }
        let stderrReadTask = Task {
            try errorPipe.fileHandleForReading.readToEnd() ?? Data()
        }

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        var didTimeout = false
        while process.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        if process.isRunning {
            didTimeout = true
            process.terminate()
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        let outputData = (try? await stdoutReadTask.value) ?? Data()
        let errorData = (try? await stderrReadTask.value) ?? Data()

        let stdoutText = String(data: outputData, encoding: .utf8) ?? ""
        let stderrText = String(data: errorData, encoding: .utf8) ?? ""

        let combinedOutput = stdoutText + (stderrText.isEmpty ? "" : "\n\(stderrText)")

        if didTimeout {
            throw NSError(
                domain: "CommandRunner",
                code: 124,
                userInfo: [
                    NSLocalizedDescriptionKey: "Command timed out after \(timeout)s: \(command)\n\(combinedOutput)"
                ]
            )
        }

        if process.terminationStatus != 0, !allowFailure {
            throw NSError(
                domain: "CommandRunner",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: combinedOutput]
            )
        }

        return (combinedOutput, process.terminationStatus)
    }
}

// MARK: - UI State Parsing

struct UIElement: Codable {
    let type: String
    let frame: Frame?
    let children: [UIElement]?
    let role: String?
    let enabled: Bool?
    let title: String?
    let subrole: String?
    let contentRequired: Bool?
    let roleDescription: String?
    let helpText: String?
    let AXFrame: String?
    let customActions: [String]?
    
    // The actual JSON uses AX prefixed fields
    let AXLabel: String?
    let AXValue: String?
    let AXUniqueId: String?
    let AXIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case type
        case frame
        case children
        case role
        case enabled
        case title
        case subrole
        case contentRequired = "content_required"
        case roleDescription = "role_description"
        case helpText = "help"
        case AXFrame
        case customActions = "custom_actions"
        case AXLabel
        case AXValue
        case AXUniqueId
        case AXIdentifier
    }
    
    struct Frame: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
    
    // Provide convenient accessors
    var label: String? {
        return AXLabel
    }
    
    var value: String? {
        return AXValue
    }
    
    var identifier: String? {
        return AXUniqueId ?? AXIdentifier
    }
}

struct UIStateParser {
    static func parseDescribeUIRoots(_ jsonString: String) throws -> [UIElement] {
        var jsonContent = jsonString

        if let jsonStart = jsonString.firstIndex(where: { $0 == "[" || $0 == "{" }) {
            jsonContent = String(jsonString[jsonStart...])
        }

        guard let data = jsonContent.data(using: .utf8) else {
            throw TestError.invalidJSON("Could not convert string to data")
        }

        // `describe-ui --json` wraps the tree in the uniform envelope
        // `{"ok":true,"data":{"raw": <tree>, ...}}`. Prefer the envelope
        // when present; fall back to bare tree shapes so tests that call
        // describe-ui through alternative paths keep working.
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(DescribeUIEnvelope.self, from: data) {
            return envelope.data.raw.asList()
        }

        if let elements = try? decoder.decode([UIElement].self, from: data) {
            return elements
        }

        let element = try decoder.decode(UIElement.self, from: data)
        return [element]
    }

    private struct DescribeUIEnvelope: Decodable {
        let ok: Bool
        let data: DescribeUIData

        struct DescribeUIData: Decodable {
            let raw: RawTree
        }

        /// The `raw` field can be either a single root (via `--point`) or
        /// an array of roots (the default tree fetch). Accept both so
        /// parseDescribeUIRoots can normalise them the same way.
        enum RawTree: Decodable {
            case single(UIElement)
            case many([UIElement])

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let elements = try? container.decode([UIElement].self) {
                    self = .many(elements)
                    return
                }
                self = .single(try container.decode(UIElement.self))
            }

            func asList() -> [UIElement] {
                switch self {
                case .single(let element): return [element]
                case .many(let elements): return elements
                }
            }
        }
    }

    static func parseDescribeUIOutput(_ jsonString: String) throws -> UIElement {
        let elements = try parseDescribeUIRoots(jsonString)
        guard let firstElement = elements.first else {
            throw TestError.invalidJSON("No UI elements found")
        }
        return firstElement
    }
    
    static func findElement(in root: UIElement, matching predicate: (UIElement) -> Bool) -> UIElement? {
        if predicate(root) {
            return root
        }
        
        if let children = root.children {
            for child in children {
                if let found = findElement(in: child, matching: predicate) {
                    return found
                }
            }
        }
        
        return nil
    }

    static func findElement(in root: UIElement, withIdentifier identifier: String) -> UIElement? {
        return findElement(in: root) { element in
            element.identifier == identifier
        }
    }
    
    static func findElementByLabel(in root: UIElement, label: String) -> UIElement? {
        return findElement(in: root) { element in
            element.label == label
        }
    }
    
    static func findElementContainingLabel(in root: UIElement, containing: String) -> UIElement? {
        return findElement(in: root) { element in
            element.label?.contains(containing) == true
        }
    }

    static func findElement(in roots: [UIElement], matching predicate: (UIElement) -> Bool) -> UIElement? {
        for root in roots {
            if let element = findElement(in: root, matching: predicate) {
                return element
            }
        }

        return nil
    }

    static func findElement(in roots: [UIElement], withIdentifier identifier: String) -> UIElement? {
        findElement(in: roots) { element in
            element.identifier == identifier
        }
    }
}

// MARK: - Test Helpers

/// Class anchor so `Bundle(for:)` resolves to this test bundle (structs and
/// enums cannot anchor a bundle lookup).
private final class BundleLocator {}

struct TestHelpers {
    private static func resolveSwiftBinPath(sourceRoot: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "build", "--show-bin-path"]
        process.currentDirectoryURL = URL(fileURLWithPath: sourceRoot)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 || output.isEmpty {
            throw TestError.commandError(
                "Unable to resolve sim-use binary path via `swift build --show-bin-path` from \(sourceRoot). \(errorOutput)"
            )
        }

        return output
    }

    static func requireE2EEnabled() throws {
        if !isE2EEnabled {
            throw TestError.commandError("E2E simulator tests are disabled. Run via ./test-runner.sh or set SIM_USE_E2E=1.")
        }
    }

    static func requireSimulatorUDID() throws -> String {
        try requireE2EEnabled()
        guard let udid = defaultSimulatorUDID, !udid.isEmpty else {
            throw TestError.commandError("SIMULATOR_UDID is required for E2E simulator tests.")
        }
        return udid
    }

    /// Get the path to the sim-use binary, in order of preference:
    ///
    /// 1. The SIM_USE_TEST_BINARY environment variable (exported by the E2E
    ///    runners).
    /// 2. The products directory containing this test bundle — the binary is
    ///    built into the same directory on both the classic
    ///    (`.build/<triple>/debug`) and SwiftBuild
    ///    (`.build/out/Products/<config>`) layouts.
    /// 3. Shelling out to `swift build --show-bin-path`. Last resort only:
    ///    from inside a running `swift test` this deadlocks on
    ///    SwiftBuild-backend toolchains (Xcode 26.6+/27), where the test run
    ///    holds the package lock the child invocation then waits on.
    static func getSimUsePath(testFile: String = #file) throws -> String {
        if let binary = ProcessInfo.processInfo.environment["SIM_USE_TEST_BINARY"],
           !binary.isEmpty {
            if FileManager.default.fileExists(atPath: binary) {
                return binary
            }
            throw TestError.unexpectedState(
                "SIM_USE_TEST_BINARY points at \(binary) but no file exists there.")
        }

        let bundleSibling = Bundle(for: BundleLocator.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("sim-use")
            .path
        if FileManager.default.fileExists(atPath: bundleSibling) {
            return bundleSibling
        }

        let sourceRoot: String
        if let srcRoot = ProcessInfo.processInfo.environment["SRC_ROOT"] {
            sourceRoot = srcRoot
        } else {
        let testFileURL = URL(fileURLWithPath: testFile)
        let testsDirectory = testFileURL.deletingLastPathComponent()  // Gets Tests/
            sourceRoot = testsDirectory.deletingLastPathComponent().path
        }

        let simUsePath = URL(fileURLWithPath: try resolveSwiftBinPath(sourceRoot: sourceRoot))
            .appendingPathComponent("sim-use")
            .path
        if FileManager.default.fileExists(atPath: simUsePath) {
            return simUsePath
        }

        throw TestError.unexpectedState("sim-use binary not found at \(simUsePath). Please run 'swift build'.")
    }
    
    static func launchPlaygroundApp(to screen: String, simulatorUDID: String? = nil) async throws {
        let udid: String
        if let simulatorUDID {
            udid = simulatorUDID
        } else {
            udid = try requireSimulatorUDID()
        }
        
        // Terminate existing instance
        let _ = try? await CommandRunner.run("xcrun simctl terminate \(udid) com.cameroncooke.SimUsePlayground")
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Launch to specific screen
        _ = try await CommandRunner.run("xcrun simctl launch \(udid) com.cameroncooke.SimUsePlayground --launch-arg \"screen=\(screen)\"")
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Resilience: a system alert (e.g. a permission prompt left by an
        // earlier suite) is presented by SpringBoard and survives an app
        // terminate/relaunch, covering the playground and swallowing every
        // subsequent gesture. If one is frontmost, dismiss it by tapping the
        // first alert button (list scope 1) and relaunch once so suites stay
        // independent regardless of run order.
        let simUsePath = try getSimUsePath()
        let (head, _) = try await CommandRunner.run("\(simUsePath) describe-ui --udid \(udid)", allowFailure: true)
        if head.contains("App: SpringBoard") {
            _ = try? await CommandRunner.run("\(simUsePath) tap '#1@1' --udid \(udid)", allowFailure: true)
            try await Task.sleep(nanoseconds: 500_000_000)
            _ = try await CommandRunner.run("xcrun simctl launch \(udid) com.cameroncooke.SimUsePlayground --launch-arg \"screen=\(screen)\"")
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
    
    static func getUIState(simulatorUDID: String? = nil) async throws -> UIElement {
        let udid: String
        if let simulatorUDID {
            udid = simulatorUDID
        } else {
            udid = try requireSimulatorUDID()
        }
        // Default `describe-ui` now prints the human outline; tests that
        // inspect the AX tree ask for the structured JSON envelope.
        let result = try await runSimUseCommand("describe-ui --json", simulatorUDID: udid)

        if result.exitCode != 0 {
            throw TestError.unexpectedState("sim-use describe-ui command failed with exit code \(result.exitCode). Output: \(result.output)")
        }

        return try UIStateParser.parseDescribeUIOutput(result.output)
    }
    
    @discardableResult
    static func runSimUseCommand(
        _ command: String,
        simulatorUDID: String? = nil,
        environment: [String: String]? = nil
    ) async throws -> ShellOutput {
        var fullCommand = command
        if let udid = simulatorUDID {
            fullCommand.append(" --udid \(udid)")
        }
        
        // Use the built executable directly for faster test execution
        let simUsePath = try getSimUsePath()
        let (output, exitCode) = try await CommandRunner.run(
            "\(simUsePath) \(fullCommand)",
            environment: environment
        )
        
        // Check if the command failed
        if exitCode != 0 {
            throw TestError.unexpectedState("sim-use command '\(fullCommand)' failed with exit code \(exitCode). Output: \(output)")
        }
        
        return ShellOutput(output: output, exitCode: exitCode)
    }

    static func runSimUseCommandAllowFailure(
        _ command: String,
        simulatorUDID: String? = nil,
        environment: [String: String]? = nil
    ) async throws -> ShellOutput {
        var fullCommand = command
        if let udid = simulatorUDID {
            fullCommand.append(" --udid \(udid)")
        }

        let simUsePath = try getSimUsePath()
        let (output, exitCode) = try await CommandRunner.run(
            "\(simUsePath) \(fullCommand)",
            environment: environment,
            allowFailure: true
        )

        return ShellOutput(output: output, exitCode: exitCode)
    }

    static func waitForProcessExit(
        _ process: Process,
        timeout: TimeInterval,
        description: String
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        if process.isRunning {
            process.terminate()
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        if process.isRunning {
            throw TestError.unexpectedState(description)
        }
    }
}

// MARK: - Errors

enum TestError: Error, CustomStringConvertible {
    case invalidJSON(String)
    case elementNotFound(String)
    case unexpectedState(String)
    case commandError(String)
    
    var description: String {
        switch self {
        case .invalidJSON(let message):
            return "Invalid JSON: \(message)"
        case .elementNotFound(let message):
            return "Element not found: \(message)"
        case .unexpectedState(let message):
            return "Unexpected state: \(message)"
        case .commandError(let message):
            return "Command error: \(message)"
        }
    }
}

// MARK: - Coordinate Parsing

struct CoordinateParser {
    static func parseCoordinates(from string: String) -> (x: Int, y: Int)? {
        // Pattern: "Tap Location: (150, 350)" or "(150, 350)"
        let pattern = #"\((\d+),\s*(\d+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else {
            return nil
        }
        
        guard let xRange = Range(match.range(at: 1), in: string),
              let yRange = Range(match.range(at: 2), in: string),
              let x = Int(string[xRange]),
              let y = Int(string[yRange]) else {
            return nil
        }
        
        return (x, y)
    }
}