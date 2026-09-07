// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

struct MJPEGTestFrame {
    let contentType: String
    let contentLength: Int
    let payload: Data
}

func firstMJPEGFrame(in stream: Data) throws -> MJPEGTestFrame {
    let headerTerminator = Data("\r\n\r\n".utf8)
    let outerHeader = try #require(
        stream.range(of: headerTerminator),
        "MJPEG stream is missing its outer HTTP header"
    )
    let boundary = Data("--mjpegstream\r\n".utf8)
    let partBoundary = try #require(
        stream.range(of: boundary, in: outerHeader.upperBound..<stream.endIndex),
        "MJPEG stream is missing its first frame boundary"
    )
    let partHeaderStart = partBoundary.upperBound
    let partHeader = try #require(
        stream.range(of: headerTerminator, in: partHeaderStart..<stream.endIndex),
        "MJPEG frame is missing its header terminator"
    )
    let headerText = String(decoding: stream[partHeaderStart..<partHeader.lowerBound], as: UTF8.self)

    func headerValue(_ name: String) -> String? {
        let prefix = "\(name):"
        return headerText.components(separatedBy: "\r\n")
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
    }

    let contentType = try #require(headerValue("Content-Type"), "MJPEG frame is missing Content-Type")
    let lengthText = try #require(headerValue("Content-Length"), "MJPEG frame is missing Content-Length")
    let contentLength = try #require(Int(lengthText), "MJPEG frame has an invalid Content-Length")
    let payloadStart = partHeader.upperBound
    let nextBoundaryPrefix = Data("\r\n--mjpegstream".utf8)
    let nextBoundary = try #require(
        stream.range(of: nextBoundaryPrefix, in: payloadStart..<stream.endIndex),
        "MJPEG stream is missing the boundary after its first frame"
    )

    return MJPEGTestFrame(
        contentType: contentType,
        contentLength: contentLength,
        payload: Data(stream[payloadStart..<nextBoundary.lowerBound])
    )
}
