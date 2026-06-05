// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// iOS Simulator backend for the `keyboard-state` verb. Mirrors the
/// flag surface of top-level `KeyboardState` and is also reachable
/// directly as `sim-use ios keyboard-state`. The top-level command
/// resolves the target platform via `PlatformRouter` and forwards
/// iOS UDIDs through here.
public struct IOSSimKeyboardStateCommand: SimUseExecutableCommand {
    /// Cross-platform result with a `platform` discriminator. iOS
    /// populates the heuristic counters; Android populates
    /// `imePackage` (the active IME's package name). The JSON
    /// encoder OMITS the other platform's fields entirely rather
    /// than emitting them as `null` — the agent sees only the
    /// signals that were actually observed and the schema reads as
    /// a tagged union (`{platform: "ios", visible, chromeKeyCount,
    /// ...}` vs `{platform: "android", visible, imePackage}`).
    public struct ExecutionResult: Codable {
        public let platform: String
        public let visible: Bool
        public let chromeKeyCount: Int?
        public let letterKeyCount: Int?
        public let idChromeCount: Int?
        public let globeSeen: Bool?
        public let imePackage: String?

        public init(
            platform: String,
            visible: Bool,
            chromeKeyCount: Int? = nil,
            letterKeyCount: Int? = nil,
            idChromeCount: Int? = nil,
            globeSeen: Bool? = nil,
            imePackage: String? = nil
        ) {
            self.platform = platform
            self.visible = visible
            self.chromeKeyCount = chromeKeyCount
            self.letterKeyCount = letterKeyCount
            self.idChromeCount = idChromeCount
            self.globeSeen = globeSeen
            self.imePackage = imePackage
        }

        enum CodingKeys: String, CodingKey {
            case platform, visible, chromeKeyCount, letterKeyCount, idChromeCount, globeSeen, imePackage
        }

        public func encode(to encoder: Encoder) throws {
            // Tagged union: nil fields are omitted from the output
            // instead of serialised as `null`. Consumers can keep
            // their decoder strict (no `?` everywhere) by branching
            // on `platform` first.
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(platform, forKey: .platform)
            try c.encode(visible, forKey: .visible)
            try c.encodeIfPresent(chromeKeyCount, forKey: .chromeKeyCount)
            try c.encodeIfPresent(letterKeyCount, forKey: .letterKeyCount)
            try c.encodeIfPresent(idChromeCount, forKey: .idChromeCount)
            try c.encodeIfPresent(globeSeen, forKey: .globeSeen)
            try c.encodeIfPresent(imePackage, forKey: .imePackage)
        }
    }

    public static let configuration = CommandConfiguration(
        commandName: "keyboard-state",
        abstract: "Report whether the on-screen software keyboard is currently visible on iOS Simulator.",
        discussion: """
        Inspects the frontmost app's accessibility tree for characteristic
        software-keyboard buttons.

        Text output:
          soft     # software keyboard visible
          hidden   # no software keyboard detected
        """
    )

    @OptionGroup public var device: DeviceOptions

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let state = try await SoftKeyboardDetector.detect(for: device.resolved, logger: logger)
        return ExecutionResult(
            platform: "ios",
            visible: state.visible,
            chromeKeyCount: state.chromeKeyCount,
            letterKeyCount: state.letterKeyCount,
            idChromeCount: state.idChromeCount,
            globeSeen: state.globeSeen
        )
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line(result.visible ? "soft" : "hidden")
    }
}