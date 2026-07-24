// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl
import SimUseCore

extension AsyncParsableCommand {
    public func setup(logger: SimUseLogger) async throws {
        try await performEssentialSetup(logger: logger)
    }
}

/// Free-function form of `setup(logger:)` — the body never touched the
/// command instance, and typed executor entry points that are not
/// command instances (e.g. `IOSSimTapCommand.performTap`) need the same
/// preflight.
public func performEssentialSetup(logger: SimUseLogger) async throws {
    // Check Xcode availability
    do {
        let xcodePath = try FBXcodeDirectory.xcodeSelectDeveloperDirectory()
        if xcodePath.isEmpty {
            logger.error().log("Xcode is not available, idb will not be able to use Simulators")
            throw CLIError(errorDescription: "Xcode is not available, idb will not be able to use Simulators")
        }
    } catch {
        logger.error().log("Xcode is not available, idb will not be able to use Simulators: \(error.localizedDescription)")
        throw CLIError(errorDescription: "Xcode is not available, idb will not be able to use Simulators")
    }

    // Load essential frameworks
    do {
        try FBSimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(logger)
    } catch {
        logger.info().log("Essential private frameworks failed to loaded.")
        throw CLIError(errorDescription: "Essential private frameworks failed to loaded.")
    }
}