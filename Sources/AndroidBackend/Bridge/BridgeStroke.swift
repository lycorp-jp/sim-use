// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Wire shape for one stroke in `POST /gesture`. Mirrors the bridge's
/// `StrokeParams` JSON object (see `bridge/.../handler/GestureHandler.kt`).
///
/// Two paths through the same envelope:
///
/// - **Linear** — populate `startX`, `startY`, `endX`, `endY` only.
///   The bridge builds a `Path` of `moveTo(start) → lineTo(end)`.
///   Existing wire shape; pre-multi-touch bridges already accept this.
/// - **Polyline** — populate `path` with ≥ 2 (x, y) points. The bridge
///   builds a `Path` of `moveTo(path[0]) → lineTo(path[1]) → … →
///   lineTo(path[n-1])`. `startX/startY/endX/endY` are computed from
///   `path[0]` / `path[last]` so older bridges (no `path` awareness)
///   still produce a linear chord rather than rejecting the request.
///   That fallback is acceptable for ≤90° rotation; clients depending
///   on true arc geometry should rely on the bridge `versionName`
///   gate to refuse old APKs.
public struct BridgeStroke: Encodable {
    public let startX: Double
    public let startY: Double
    public let endX: Double
    public let endY: Double
    public let startTime: Int
    public let duration: Int
    public let path: [BridgeStrokePoint]?

    public init(startX: Double, startY: Double, endX: Double, endY: Double, startTime: Int, duration: Int, path: [BridgeStrokePoint]? = nil) {
        self.startX = startX
        self.startY = startY
        self.endX = endX
        self.endY = endY
        self.startTime = startTime
        self.duration = duration
        self.path = path
    }

    public static func linear(
        startX: Double, startY: Double,
        endX: Double, endY: Double,
        startTime: Int, duration: Int
    ) -> BridgeStroke {
        BridgeStroke(
            startX: startX, startY: startY,
            endX: endX, endY: endY,
            startTime: startTime, duration: duration,
            path: nil
        )
    }

    /// Polyline stroke with ≥ 2 waypoints. The linear fallback fields
    /// are populated from the first and last waypoint so a bridge that
    /// ignores `path` still produces a sensible chord.
    public static func polyline(
        points: [BridgeStrokePoint],
        startTime: Int,
        duration: Int
    ) -> BridgeStroke {
        precondition(points.count >= 2, "BridgeStroke.polyline requires at least 2 points")
        let first = points.first!
        let last = points.last!
        return BridgeStroke(
            startX: first.x, startY: first.y,
            endX: last.x, endY: last.y,
            startTime: startTime, duration: duration,
            path: points
        )
    }

    enum CodingKeys: String, CodingKey {
        case startX, startY, endX, endY, startTime, duration, path
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(startX, forKey: .startX)
        try c.encode(startY, forKey: .startY)
        try c.encode(endX, forKey: .endX)
        try c.encode(endY, forKey: .endY)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(duration, forKey: .duration)
        if let path {
            try c.encode(path, forKey: .path)
        }
    }
}

public struct BridgeStrokePoint: Encodable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

struct BridgeGesturePayload: Encodable {
    let strokes: [BridgeStroke]
}