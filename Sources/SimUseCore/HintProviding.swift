// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Opt-in protocol for errors that carry an actionable recovery hint.
/// When present, the hint surfaces in the `--json` error envelope so
/// agents can self-correct without re-parsing the human string.
public protocol HintProviding {
    var hint: String? { get }
}