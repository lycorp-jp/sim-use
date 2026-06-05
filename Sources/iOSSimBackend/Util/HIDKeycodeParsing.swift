// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation

/// Parse a comma-separated list of integers, surfacing every malformed
/// token in the error message at once instead of bailing on the first
/// failure. Used by the HID-keyed verbs (`key-combo`, `key-sequence`)
/// and the `batch` step parser to keep error UX consistent between the
/// single-shot and batched forms.
func parseCommaSeparatedIntsStrict(_ rawValue: String, fieldName: String) throws -> [Int] {
    let rawTokens = rawValue
        .split(separator: ",", omittingEmptySubsequences: false)
        .map { String($0).trimmingCharacters(in: .whitespaces) }

    let invalidTokens = rawTokens.filter { token in
        token.isEmpty || Int(token) == nil
    }
    guard invalidTokens.isEmpty else {
        throw ValidationError("All \(fieldName) must be valid integers. Invalid token(s): \(invalidTokens.joined(separator: ", "))")
    }

    return rawTokens.compactMap(Int.init)
}