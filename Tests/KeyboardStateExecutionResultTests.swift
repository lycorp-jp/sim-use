// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import SimUse
@testable import iOSSimBackend

/// Verifies the tagged-union JSON shape for
/// `KeyboardState.ExecutionResult`. The encoder must OMIT
/// platform-irrelevant fields (instead of emitting them as
/// `null`) so the schema reads as a tagged union keyed by
/// `platform`, and downstream decoders can stay strict.
final class KeyboardStateExecutionResultTests: XCTestCase {

    private func encoded(_ result: KeyboardState.ExecutionResult) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        let json = try JSONSerialization.jsonObject(with: data)
        return json as? [String: Any] ?? [:]
    }

    /// iOS variant must carry the heuristic counters and NOT
    /// carry `imePackage` (Android-only).
    func testIOSEnvelopeOmitsAndroidFields() throws {
        let result = KeyboardState.ExecutionResult(
            platform: "ios",
            visible: true,
            chromeKeyCount: 6,
            letterKeyCount: 26,
            idChromeCount: 7,
            globeSeen: true
        )
        let dict = try encoded(result)
        XCTAssertEqual(dict["platform"] as? String, "ios")
        XCTAssertEqual(dict["visible"] as? Bool, true)
        XCTAssertEqual(dict["chromeKeyCount"] as? Int, 6)
        XCTAssertFalse(dict.keys.contains("imePackage"),
                       "iOS envelope must not include null imePackage")
    }

    /// Android variant must carry `imePackage` and NOT carry the
    /// iOS heuristic counters.
    func testAndroidEnvelopeOmitsIOSFields() throws {
        let result = KeyboardState.ExecutionResult(
            platform: "android",
            visible: true,
            imePackage: "com.google.android.inputmethod.latin"
        )
        let dict = try encoded(result)
        XCTAssertEqual(dict["platform"] as? String, "android")
        XCTAssertEqual(dict["visible"] as? Bool, true)
        XCTAssertEqual(dict["imePackage"] as? String, "com.google.android.inputmethod.latin")
        for key in ["chromeKeyCount", "letterKeyCount", "idChromeCount", "globeSeen"] {
            XCTAssertFalse(dict.keys.contains(key),
                           "Android envelope must not include null \(key)")
        }
    }

    /// `visible=false` on Android with no IME package — the platform
    /// discriminator is still present, and `imePackage` is omitted
    /// (no spurious null).
    func testAndroidHiddenStateOmitsImePackage() throws {
        let result = KeyboardState.ExecutionResult(
            platform: "android",
            visible: false
        )
        let dict = try encoded(result)
        XCTAssertEqual(dict["platform"] as? String, "android")
        XCTAssertEqual(dict["visible"] as? Bool, false)
        XCTAssertFalse(dict.keys.contains("imePackage"))
    }
}