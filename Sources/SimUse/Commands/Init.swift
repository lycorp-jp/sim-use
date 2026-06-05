// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Darwin
import Foundation
import iOSSimBackend
import SimUseCore

struct Init: SimUseExecutableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Install sim-use skill files for detected AI clients.",
        discussion: """
        Installs the bundled `sim-use` skill markdown into the appropriate
        client config directory (Claude Code, AGENTS-style clients, or a
        custom --dest path).

        This command operates on the *host* — it does not interact with any
        simulator or device, and intentionally accepts no --udid. If you
        meant to bootstrap an Android device-bridge APK, use:
          sim-use android init --udid <serial>

        The two `init` verbs share a name but are unrelated: the top-level
        one installs AI-client skill files locally, the Android subcommand
        installs an APK on a connected device and grants accessibility.
        """
    )

    enum Client: String, ExpressibleByArgument, CaseIterable {
        case auto
        case claude
        case agents
    }

    enum ExecutionResult: Codable {
        case printedSkill(markdown: String)
        case installed(entries: [String])
        case uninstalled(entries: [String])
    }

    @Option(help: "Target client: auto, claude, or agents. Defaults to auto-detect.")
    var client: Client = .auto

    @Option(help: "Custom destination skills directory (overrides --client).")
    var dest: String?

    @Flag(help: "Overwrite an existing installed skill.")
    var force: Bool = false

    @Flag(help: "Remove installed sim-use skill from target directories.")
    var uninstall: Bool = false

    @Flag(name: .customLong("print"), help: "Print bundled skill content to stdout.")
    var printSkill: Bool = false

    @Flag(name: .customLong("json"), help: "Emit the result as compact JSON describing installed, uninstalled, or printed skill content.")
    var jsonOutput: Bool = false

    func validate() throws {
        if printSkill, uninstall {
            throw ValidationError("--print cannot be used with --uninstall")
        }

        if printSkill, force {
            throw ValidationError("--print cannot be used with --force")
        }

        if printSkill, dest != nil {
            throw ValidationError("--print cannot be used with --dest")
        }

        if printSkill, client != .auto {
            throw ValidationError("--print cannot be used with --client")
        }
    }

    func execute() async throws -> ExecutionResult {
        if !printSkill, !isInteractiveTTY(), dest == nil, client == .auto {
            throw CLIError(
                errorDescription: "Non-interactive mode requires --client or --dest for init. Use --print to output the skill content."
            )
        }

        if printSkill {
            return .printedSkill(markdown: try Self.loadSkillMarkdown())
        }

        let targets = try resolveTargets(for: uninstall ? .uninstall : .install)

        if uninstall {
            return .uninstalled(entries: try uninstallSkill(from: targets))
        }

        return .installed(entries: try installSkill(to: targets))
    }

    func format(_ result: ExecutionResult) -> CommandOutput {
        switch result {
        case .printedSkill(let markdown):
            return .raw(markdown)
        case .installed(let entries):
            return .raw(entries.map { "Installed sim-use skill -> \($0)\n" }.joined())
        case .uninstalled(let entries):
            if entries.isEmpty {
                return .raw("No installed sim-use skill directories were found.\n")
            }
            return .raw(entries.map { "Removed sim-use skill -> \($0)\n" }.joined())
        }
    }

    private enum Operation {
        case install
        case uninstall
    }

    private struct ClientInfo {
        let id: Client
        let name: String
        let skillsDirectory: URL
    }

    private static func skillBundleDirectory() throws -> URL {
        guard let url = Bundle.module.url(
            forResource: "SKILL",
            withExtension: "md",
            subdirectory: "skills/sim-use"
        ) else {
            throw CLIError(errorDescription: "Bundled sim-use skill source was not found.")
        }
        return url.deletingLastPathComponent()
    }

    private static func loadSkillMarkdown() throws -> String {
        let dir = try skillBundleDirectory()
        let skillFile = dir.appendingPathComponent("SKILL.md")
        do {
            return try String(contentsOf: skillFile, encoding: .utf8)
        } catch {
            throw CLIError(errorDescription: "Failed to read bundled sim-use skill source: \(error.localizedDescription)")
        }
    }

    private func installSkill(to targets: [ClientInfo]) throws -> [String] {
        let sourceDirectory = try Self.skillBundleDirectory()
        var installedPaths: [String] = []

        for target in targets {
            let targetDirectory = target.skillsDirectory.appendingPathComponent("sim-use", isDirectory: true)

            if FileManager.default.fileExists(atPath: targetDirectory.path), !force {
                throw CLIError(
                    errorDescription: "Skill already installed at \(targetDirectory.path). Re-run with --force to overwrite."
                )
            }

            do {
                if FileManager.default.fileExists(atPath: targetDirectory.path) {
                    try FileManager.default.removeItem(at: targetDirectory)
                }
                try FileManager.default.createDirectory(
                    at: targetDirectory.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: sourceDirectory, to: targetDirectory)
                installedPaths.append("\(target.name): \(targetDirectory.path)")
            } catch {
                throw CLIError(
                    errorDescription: "Failed to install sim-use skill for \(target.name): \(error.localizedDescription)"
                )
            }
        }

        if installedPaths.isEmpty {
            throw CLIError(errorDescription: "No install targets resolved.")
        }

        return installedPaths
    }

    private func uninstallSkill(from targets: [ClientInfo]) throws -> [String] {
        var removedPaths: [String] = []

        for target in targets {
            let targetDirectory = target.skillsDirectory.appendingPathComponent("sim-use", isDirectory: true)
            guard FileManager.default.fileExists(atPath: targetDirectory.path) else {
                continue
            }

            do {
                try FileManager.default.removeItem(at: targetDirectory)
                removedPaths.append("\(target.name): \(targetDirectory.path)")
            } catch {
                throw CLIError(
                    errorDescription: "Failed to uninstall sim-use skill for \(target.name): \(error.localizedDescription)"
                )
            }
        }

        return removedPaths
    }

    private func resolveTargets(for operation: Operation) throws -> [ClientInfo] {
        if let destination = dest {
            let resolvedDestination = try Self.resolveDestinationURL(from: destination)
            return [ClientInfo(id: .auto, name: "Custom", skillsDirectory: resolvedDestination)]
        }

        if client != .auto {
            return [try Self.clientInfo(for: client)]
        }

        let detected = Self.detectClients()
        if detected.isEmpty {
            if operation == .uninstall {
                return []
            }

            throw CLIError(
                errorDescription: "No supported AI clients detected. Use --client, --dest, or --print."
            )
        }

        return detected
    }

    private static func detectClients() -> [ClientInfo] {
        Client.allCases
            .filter { $0 != .auto }
            .compactMap { try? clientInfoIfDetected(for: $0) }
    }

    private static func clientInfoIfDetected(for client: Client) throws -> ClientInfo? {
        let homeDirectory = homeDirectoryPath()
        let clientRootPath: String

        switch client {
        case .claude:
            clientRootPath = homeDirectory + "/.claude"
        case .agents:
            clientRootPath = homeDirectory + "/.agents"
        case .auto:
            return nil
        }

        guard FileManager.default.fileExists(atPath: clientRootPath) else {
            return nil
        }

        return try clientInfo(for: client)
    }

    private static func clientInfo(for client: Client) throws -> ClientInfo {
        let homeDirectory = homeDirectoryPath()

        switch client {
        case .claude:
            return ClientInfo(
                id: .claude,
                name: "Claude Code",
                skillsDirectory: URL(fileURLWithPath: homeDirectory).appendingPathComponent(".claude/skills", isDirectory: true)
            )
        case .agents:
            return ClientInfo(
                id: .agents,
                name: "Agents Skills",
                skillsDirectory: URL(fileURLWithPath: homeDirectory).appendingPathComponent(".agents/skills", isDirectory: true)
            )
        case .auto:
            throw CLIError(errorDescription: "Auto is not a concrete client target.")
        }
    }

    private static func homeDirectoryPath() -> String {
        ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func isInteractiveTTY() -> Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    }

    private static func resolveDestinationURL(from rawValue: String) throws -> URL {
        let expandedPath = expandHomePrefix(rawValue)
        let standardizedPath = URL(fileURLWithPath: expandedPath).standardizedFileURL.path

        guard standardizedPath != "/" else {
            throw CLIError(errorDescription: "Refusing to use filesystem root as skills destination.")
        }

        return URL(fileURLWithPath: standardizedPath, isDirectory: true)
    }

    private static func expandHomePrefix(_ path: String) -> String {
        if path == "~" {
            return homeDirectoryPath()
        }

        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            return URL(fileURLWithPath: homeDirectoryPath()).appendingPathComponent(suffix).path
        }

        return path
    }
}