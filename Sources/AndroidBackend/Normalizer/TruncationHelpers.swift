// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Shared label/value escape + truncation helpers. Mirrors the iOS
/// `OutlineFormatter` private helpers so cross-platform outlines render
/// identically. Internal whitespace runs collapse to single spaces.
enum TruncationHelpers {
    static let ellipsis = "…"

    /// TODO(width-aware-truncation): Truncates by grapheme-cluster
    /// count, not by rendered display width. CJK / emoji-ZWJ clusters
    /// render double-width in a monospace terminal, so a 60-grapheme
    /// label can occupy ~90 columns and overshoot the outline's
    /// width budget. iOS's `OutlineFormatter` has the identical
    /// behaviour — parity is preserved deliberately so the two
    /// platforms render the same label the same way today. The
    /// width-aware fix (East-Asian-width table lookup; treat ZWJ
    /// sequences as the width of their first base + joined emoji)
    /// has to land on both platforms together to keep that parity,
    /// which is why it is parked here rather than fixed unilaterally.
    static func escapeAndTruncate(_ s: String, maxGraphemes: Int) -> String {
        let collapsed = collapseWhitespace(s)
        let escaped = escape(collapsed)
        let clusters = Array(escaped)
        guard clusters.count > maxGraphemes else { return escaped }
        let keep = max(0, maxGraphemes - 1)
        return String(clusters.prefix(keep)) + ellipsis
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func collapseWhitespace(_ s: String) -> String {
        var mapped = String.UnicodeScalarView()
        mapped.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                mapped.append(" ")
            } else {
                mapped.append(scalar)
            }
        }
        var out = ""
        out.reserveCapacity(mapped.count)
        var previousWasSpace = false
        for scalar in mapped {
            let isSpace = scalar == " "
            if isSpace && previousWasSpace { continue }
            out.unicodeScalars.append(scalar)
            previousWasSpace = isSpace
        }
        return out
    }
}