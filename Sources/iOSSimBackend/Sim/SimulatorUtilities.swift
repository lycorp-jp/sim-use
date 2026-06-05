// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBControlCore
import FBSimulatorControl

// MARK: - Utility Functions
public func getSimulatorSet(
    deviceSetPath: String?,
    logger: SimUseLogger,
    reporter: FBEventReporter
) async throws -> FBSimulatorSet {
    let configuration = FBSimulatorControlConfiguration(
        deviceSetPath: deviceSetPath,
        logger: logger,
        reporter: reporter
    )

    do {
        let controlSet = try FBSimulatorControl.withConfiguration(configuration)
        return controlSet.set
    } catch {
        logger.info().log("FBSimulatorControl failed to initialize.")
        throw error
    }
} 