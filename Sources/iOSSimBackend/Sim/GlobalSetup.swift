// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBControlCore
import FBSimulatorControl
import ObjectiveC // For objc_lookUpClass
import SimUseCore

@MainActor
public func performGlobalSetup(logger: SimUseLogger) async throws {
    logger.info().log("Performing global setup...")

    // Check Xcode availability
    logger.info().log("Checking Xcode availability...")
    do {
        let xcodePath = try FBXcodeDirectory.xcodeSelectDeveloperDirectory()
        if xcodePath.isEmpty {
            let errorMessage = "Xcode is not available (xcode-select path is empty). FBSimulatorControl may not function correctly."
            logger.error().log(errorMessage)
            throw CLIError(errorDescription: errorMessage)
        }
        logger.info().log("Xcode is available at: \(xcodePath)")
    } catch {
        let errorMessage = "Failed to check Xcode availability: \(error.localizedDescription)"
        logger.error().log(errorMessage)
        throw CLIError(errorDescription: errorMessage)
    }

    // Load essential private frameworks
    logger.info().log("Loading essential private frameworks via FBSimulatorControlFrameworkLoader...")
    do {
        try FBSimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(logger)
        logger.info().log("Successfully loaded essential private frameworks (according to FBSimulatorControlFrameworkLoader).")

        // Xcode 27 removed SimulatorKit; fail fast with an actionable
        // message instead of the cryptic dyld "does not exist" below.
        try XcodeCompatibility.assertSimulatorKitAvailable(logger: logger)

        // Load Xcode frameworks (including SimulatorKit)
        logger.info().log("Loading Xcode frameworks (including SimulatorKit)...")
        try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
        logger.info().log("Successfully loaded Xcode frameworks.")

        // Explicitly check if the critical class is now available
        let clientClassName = "SimulatorKit.SimDeviceLegacyHIDClient"
        let clientClass: AnyClass? = objc_lookUpClass(clientClassName)
        if clientClass == nil {
            let criticalMessage = "CRITICAL FAILURE: Class '\(clientClassName)' NOT FOUND by objc_lookUpClass even after FBSimulatorControlFrameworkLoader call."
            logger.error().log(criticalMessage)
            throw CLIError(errorDescription: criticalMessage) // This should halt execution if class isn't found
        } else {
            logger.info().log("CONFIRMED: Class '\(clientClassName)' was successfully found by objc_lookUpClass.")
        }

    } catch {
        let errorMessage = "Failed to load essential private frameworks: \(error.localizedDescription)"
        logger.error().log(errorMessage)
        throw CLIError(errorDescription: errorMessage)
    }
    logger.info().log("Global setup complete.")
} 