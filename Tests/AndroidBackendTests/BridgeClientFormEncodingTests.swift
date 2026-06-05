// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend

/// Guards `BridgeClient.formSafeBase64` against the `+` → space corruption
/// that previously broke `type` / `paste` on multi-byte payloads (CJK,
/// emoji). The bridge speaks `application/x-www-form-urlencoded` and runs
/// values through `URLDecoder.decode`, so any unescaped `+` in the base64
/// arrives as a space and the bridge replies `{"code":"invalid_base64"}`.
final class BridgeClientFormEncodingTests: XCTestCase {

    /// ASCII-only payload whose base64 is free of `+` and `/` — the
    /// only encoded character is the trailing `=` padding, which now
    /// becomes `%3D`. The body length grows by 2 bytes per padding
    /// character; that's the cost the encoder pays in exchange for
    /// forward-compat with stricter form decoders.
    func testAsciiPayloadEscapesOnlyPadding() {
        let encoded = BridgeClient.formSafeBase64(Data("hello world".utf8))
        XCTAssertEqual(encoded, "aGVsbG8gd29ybGQ%3D")
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
    }

    /// The exact payload that triggered the bug report: Japanese + Chinese
    /// + emoji produces base64 with a `+` (`...8J+Qvg==`). After the fix
    /// the `+` must be percent-encoded as `%2B`.
    func testCjkPlusEmojiEscapesPlus() {
        let raw = Data("こんにちは中文🐾".utf8).base64EncodedString()
        XCTAssertTrue(raw.contains("+"), "test premise: this payload's base64 must contain '+'")

        let encoded = BridgeClient.formSafeBase64(Data("こんにちは中文🐾".utf8))
        XCTAssertFalse(encoded.contains("+"), "encoder must strip raw '+' from output")
        XCTAssertTrue(encoded.contains("%2B"), "encoder must emit '%2B' in '+' position")
        // Padding `=` should now also be percent-encoded — see the
        // padding-specific test for the rationale.
        let expected = raw
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "/", with: "%2F")
            .replacingOccurrences(of: "=", with: "%3D")
        XCTAssertEqual(encoded, expected)
    }

    /// `/` is technically reserved in URI grammar even though `URLDecoder`
    /// would pass it through — encode defensively.
    func testSlashEscaped() {
        // 4 bytes 0xFF produces "////" in base64.
        let encoded = BridgeClient.formSafeBase64(Data([0xFF, 0xFF, 0xFF]))
        XCTAssertEqual(encoded, "%2F%2F%2F%2F")
    }

    /// Padding `=` is also percent-encoded as `%3D`. The bridge parser
    /// today splits on the first `=` per pair (see
    /// `HttpServer.parseFormUrlEncoded`), so unescaped padding works
    /// in value position — but the bridge is also the place where a
    /// future swap to e.g. `URI.getQuery` would silently corrupt
    /// every padded payload. Encoding `=` upfront removes that
    /// future failure mode at the cost of ~3 bytes per pair.
    func testPaddingEqualsPercentEncoded() {
        let encoded = BridgeClient.formSafeBase64(Data("a".utf8))
        XCTAssertEqual(encoded, "YQ%3D%3D")
    }

    /// Round-trip: percent-decode the encoded form, base64-decode, and
    /// expect the original UTF-8 bytes back. Exercises the contract the
    /// bridge's Kotlin side enforces.
    func testRoundTripThroughFormDecode() throws {
        let original = "Hello, 世界! 🚀+/=?&"
        let encoded = BridgeClient.formSafeBase64(Data(original.utf8))

        let percentDecoded = encoded
            .replacingOccurrences(of: "%2B", with: "+")
            .replacingOccurrences(of: "%2F", with: "/")
            .replacingOccurrences(of: "%3D", with: "=")
        let bytes = try XCTUnwrap(Data(base64Encoded: percentDecoded))
        XCTAssertEqual(String(data: bytes, encoding: .utf8), original)
    }
}