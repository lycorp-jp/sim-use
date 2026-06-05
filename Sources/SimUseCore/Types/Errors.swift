// SPDX-License-Identifier: Apache-2.0
import Foundation

// MARK: - Error Types

/// Carries a human-readable error message that should reach the user
/// verbatim. Conforms to `LocalizedError` so `error.localizedDescription`
/// returns this message instead of Foundation's NSError bridge default
/// (`"The operation couldn't be completed. (CLIError error 1.)"`).
///
/// `errorDescription` is declared as `String?` (not `String`) so the
/// LocalizedError protocol witness is properly installed — Foundation's
/// bridging machinery only routes `localizedDescription` through the
/// LocalizedError implementation when the witness signature matches the
/// protocol exactly. Internal call sites pass non-optional strings; the
/// implicit Optional promotion keeps every existing callsite unchanged.
/// (LINEIOS-216942: required so daemon-side `DaemonErrorKind.classify`
/// can actually pattern-match the message and detect stale simulators.)
public struct CLIError: LocalizedError {
    public let errorDescription: String?

    public init(errorDescription: String) {
        self.errorDescription = errorDescription
    }
}