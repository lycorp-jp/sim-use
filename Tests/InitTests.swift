// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Suite("Init Command Tests")
struct InitTests {
    @Test("print outputs skill content")
    func printOutputsSkill() async throws {
        let result = try await TestHelpers.runSimUseCommand("init --print")
        #expect(result.output.contains("name: sim-use"))
        #expect(result.output.contains("Drive iOS Simulator and Android"))
    }

    @Test("installs skill to custom destination")
    func installsToCustomDestination() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillsDir = tempRoot.appendingPathComponent("skills", isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        _ = try await TestHelpers.runSimUseCommand("init --dest \(skillsDir.path)")

        let installedFile = skillsDir.appendingPathComponent("sim-use/SKILL.md").path
        #expect(FileManager.default.fileExists(atPath: installedFile))
    }

    @Test("existing skill requires force")
    func existingSkillRequiresForce() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillsDir = tempRoot.appendingPathComponent("skills", isDirectory: true)
        let installedDir = skillsDir.appendingPathComponent("sim-use", isDirectory: true)
        let installedFile = installedDir.appendingPathComponent("SKILL.md", isDirectory: false)

        try FileManager.default.createDirectory(at: installedDir, withIntermediateDirectories: true)
        try "old-content".write(to: installedFile, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let failedResult = try await TestHelpers.runSimUseCommandAllowFailure("init --dest \(skillsDir.path)")
        #expect(failedResult.exitCode != 0)
        #expect(failedResult.output.contains("--force"))

        _ = try await TestHelpers.runSimUseCommand("init --dest \(skillsDir.path) --force")
        let newContent = try String(contentsOf: installedFile, encoding: .utf8)
        #expect(newContent.contains("name: sim-use"))
    }

    @Test("uninstall removes installed directory")
    func uninstallRemovesInstalledDirectory() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillsDir = tempRoot.appendingPathComponent("skills", isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        _ = try await TestHelpers.runSimUseCommand("init --dest \(skillsDir.path)")
        _ = try await TestHelpers.runSimUseCommand("init --dest \(skillsDir.path) --uninstall")

        let installedDirectory = skillsDir.appendingPathComponent("sim-use", isDirectory: true).path
        #expect(!FileManager.default.fileExists(atPath: installedDirectory))
    }

    @Test("non-interactive mode requires explicit target")
    func nonInteractiveModeRequiresExplicitTarget() async throws {
        let result = try await TestHelpers.runSimUseCommandAllowFailure("init")
        #expect(result.exitCode != 0)
        #expect(result.output.contains("Non-interactive mode requires --client or --dest"))
    }

    @Test("refuses root destination")
    func refusesRootDestination() async throws {
        let result = try await TestHelpers.runSimUseCommandAllowFailure("init --dest /")
        #expect(result.exitCode != 0)
        #expect(result.output.contains("filesystem root"))
    }
}