// SPDX-License-Identifier: Apache-2.0
import Foundation

// Minimal HTTP/1.1 request + response types for the Viewer's local
// server. Intentionally a small subset of full HTTP: single-shot per
// connection, no keep-alive, no chunked encoding, no streaming. The
// Viewer only ever serves one user from one browser tab against a
// resource tree that fits comfortably in memory, so a stricter
// implementation would be over-engineered.

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse {
    let status: Int
    let reason: String
    let headers: [String: String]
    let body: Data

    static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        let data: Data
        if let object = object as? Data {
            data = object
        } else if JSONSerialization.isValidJSONObject(object) {
            data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        } else {
            data = Data()
        }
        return HTTPResponse(
            status: status,
            reason: reasonPhrase(for: status),
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Cache-Control": "no-store",
            ],
            body: data
        )
    }

    static func data(_ data: Data, contentType: String, status: Int = 200, cacheControl: String = "no-store") -> HTTPResponse {
        HTTPResponse(
            status: status,
            reason: reasonPhrase(for: status),
            headers: [
                "Content-Type": contentType,
                "Cache-Control": cacheControl,
            ],
            body: data
        )
    }

    static func plain(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(
            status: status,
            reason: reasonPhrase(for: status),
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(message.utf8)
        )
    }

    /// Returns a copy suitable for responding to HEAD: same status and
    /// headers as the GET equivalent, including a Content-Length that
    /// matches what GET would have sent, but an empty body. RFC 7230
    /// requires HEAD responses to advertise the same Content-Length.
    func headOnly() -> HTTPResponse {
        var newHeaders = headers
        newHeaders["Content-Length"] = String(body.count)
        return HTTPResponse(status: status, reason: reason, headers: newHeaders, body: Data())
    }

    func serialize() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var allHeaders = headers
        if allHeaders["Content-Length"] == nil {
            allHeaders["Content-Length"] = String(body.count)
        }
        // Single-shot connection model — tell the client not to wait
        // for another request on the same socket. Saves us implementing
        // keep-alive state.
        allHeaders["Connection"] = "close"
        for (k, v) in allHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}

private func reasonPhrase(for status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 204: return "No Content"
    case 301: return "Moved Permanently"
    case 302: return "Found"
    case 400: return "Bad Request"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 500: return "Internal Server Error"
    case 502: return "Bad Gateway"
    default:  return "OK"
    }
}

enum HTTPParseResult {
    /// Headers parsed; body still incomplete. Caller should keep
    /// reading until it has `expectedBodyLength` more bytes.
    case needMoreBody(headerEnd: Int, expectedBodyLength: Int)
    /// Request fully parsed.
    case ready(HTTPRequest, consumedBytes: Int)
    /// Headers not yet complete.
    case needMoreHeaders
    /// Malformed request that can't be recovered.
    case invalid(reason: String)
}

enum HTTPParser {
    /// Parses an HTTP/1.1 request from an accumulating buffer. Returns
    /// .needMoreHeaders / .needMoreBody until a full request is
    /// available, at which point .ready carries the parsed request and
    /// the number of bytes consumed from the buffer.
    static func parse(_ buffer: Data) -> HTTPParseResult {
        guard let headerEnd = findHeaderEnd(in: buffer) else {
            return .needMoreHeaders
        }
        let headerData = buffer.prefix(headerEnd)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .invalid(reason: "headers are not valid UTF-8")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .invalid(reason: "empty request")
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else {
            return .invalid(reason: "malformed request line: \(requestLine)")
        }
        let method = parts[0]
        let target = parts[1]
        // parts[2] is the HTTP version; we accept anything that looks
        // like HTTP/1.x without parsing further.

        let (path, query) = splitTarget(target)

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = headerEnd + 4 // skip the CRLFCRLF
        let expectedBodyLength: Int
        if let rawLength = headers["content-length"] {
            // A present-but-malformed or negative Content-Length is a
            // client error, not a recoverable default. Treating "-1" as 0
            // used to slip through and later crash subdata(in:) with an
            // inverted range; reject it up front instead.
            guard let parsed = Int(rawLength), parsed >= 0 else {
                return .invalid(reason: "invalid Content-Length: \(rawLength)")
            }
            expectedBodyLength = parsed
        } else {
            expectedBodyLength = 0
        }
        let available = buffer.count - bodyStart
        if available < expectedBodyLength {
            return .needMoreBody(headerEnd: headerEnd, expectedBodyLength: expectedBodyLength)
        }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + expectedBodyLength))
        let request = HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
        return .ready(request, consumedBytes: bodyStart + expectedBodyLength)
    }

    private static let crlfcrlf: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]

    private static func findHeaderEnd(in buffer: Data) -> Int? {
        // Returns the index at which the header section ends (i.e. the
        // index of the first byte of \r\n\r\n). Linear scan is fine —
        // headers are O(KB) at most.
        guard buffer.count >= 4 else { return nil }
        let needle = crlfcrlf
        return buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var i = 0
            while i <= n - 4 {
                if bytes[i] == needle[0]
                    && bytes[i + 1] == needle[1]
                    && bytes[i + 2] == needle[2]
                    && bytes[i + 3] == needle[3]
                {
                    return i
                }
                i += 1
            }
            return nil
        }
    }

    private static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        guard let qIndex = target.firstIndex(of: "?") else {
            return (target, [:])
        }
        let path = String(target[..<qIndex])
        let queryString = String(target[target.index(after: qIndex)...])
        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let key = percentDecode(kv[0])
            let value = kv.count > 1 ? percentDecode(kv[1]) : ""
            query[key] = value
        }
        return (path, query)
    }

    private static func percentDecode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }
}