// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBControlCore

// MARK: - Event Reporter
@objc public final class EmptyEventReporter: NSObject, FBEventReporter {
    @objc public static let shared = EmptyEventReporter()
    public var metadata: [String: String] = [:]
    public func report(_ subject: FBEventReporterSubject) {}
    public func addMetadata(_ metadata: [String: String]) {}
} 