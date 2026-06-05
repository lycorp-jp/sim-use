// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
import Foundation
import Testing

/// Regression coverage for the Viewer's minimal HTTP/1.1 request parser.
/// The focus is on malformed Content-Length values that previously crashed
/// the server via an inverted Range in `subdata(in:)`.
struct HTTPParserTests {
    private func parse(_ raw: String) -> HTTPParseResult {
        HTTPParser.parse(Data(raw.utf8))
    }

    @Test("negative Content-Length is rejected instead of crashing")
    func negativeContentLength() {
        let raw = "POST /api/devices HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: -1\r\n\r\n"
        guard case .invalid = parse(raw) else {
            Issue.record("expected .invalid for negative Content-Length")
            return
        }
    }

    @Test("non-numeric Content-Length is rejected")
    func nonNumericContentLength() {
        let raw = "POST /api/devices HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: abc\r\n\r\n"
        guard case .invalid = parse(raw) else {
            Issue.record("expected .invalid for non-numeric Content-Length")
            return
        }
    }

    @Test("missing Content-Length parses with an empty body")
    func missingContentLength() {
        let raw = "GET /api/devices HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        guard case let .ready(request, _) = parse(raw) else {
            Issue.record("expected .ready for a well-formed request")
            return
        }
        #expect(request.method == "GET")
        #expect(request.body.isEmpty)
    }

    @Test("valid Content-Length consumes exactly the advertised body")
    func validContentLength() {
        let raw = "POST /api/devices HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\n\r\nhello"
        guard case let .ready(request, consumed) = parse(raw) else {
            Issue.record("expected .ready for a complete body")
            return
        }
        #expect(request.body == Data("hello".utf8))
        #expect(consumed == raw.utf8.count)
    }
}