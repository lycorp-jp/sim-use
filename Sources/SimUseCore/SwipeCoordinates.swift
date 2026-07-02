// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation

public struct CoordinatePair: ExpressibleByArgument, Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init?(argument: String) {
        guard let parsed = Self.parse(argument) else { return nil }
        self = parsed
    }

    private static func parse(_ raw: String) -> CoordinatePair? {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let xRaw = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let yRaw = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let x = Double(xRaw), let y = Double(yRaw) else { return nil }
        return CoordinatePair(x: x, y: y)
    }
}

public struct SwipeCoordinates: Codable, Equatable, Sendable {
    public let startX: Double
    public let startY: Double
    public let endX: Double
    public let endY: Double

    public init(startX: Double, startY: Double, endX: Double, endY: Double) {
        self.startX = startX
        self.startY = startY
        self.endX = endX
        self.endY = endY
    }
}

public enum SwipeCoordinateResolver {
    public static func resolve(
        startX: Double?,
        startY: Double?,
        endX: Double?,
        endY: Double?,
        from: CoordinatePair?,
        to: CoordinatePair?,
        positional: [CoordinatePair]
    ) throws -> SwipeCoordinates {
        guard positional.count <= 2 else {
            throw ValidationError("Swipe accepts at most two positional coordinate pairs: <from x,y> <to x,y>.")
        }

        let legacyValues = [startX, startY, endX, endY]
        let legacyCount = legacyValues.compactMap { $0 }.count
        let hasLegacy = legacyCount == 4
        let partialLegacy = legacyCount > 0 && legacyCount < 4
        let hasNamedPair = from != nil && to != nil
        let partialNamedPair = (from != nil) != (to != nil)
        let hasPositionalPair = positional.count == 2
        let partialPositionalPair = positional.count == 1

        if partialLegacy || partialNamedPair || partialPositionalPair {
            throw ValidationError("Specify swipe coordinates using one complete form only: --from x,y --to x,y, positional <x,y> <x,y>, or all of --start-x --start-y --end-x --end-y.")
        }

        let completedForms = [hasLegacy, hasNamedPair, hasPositionalPair].filter { $0 }.count
        guard completedForms > 0 else {
            throw ValidationError("Specify swipe coordinates with --from x,y --to x,y, positional <x,y> <x,y>, or all of --start-x --start-y --end-x --end-y.")
        }
        guard completedForms == 1 else {
            throw ValidationError("Specify only one swipe coordinate form: --from/--to, positional <x,y> <x,y>, or --start-x/--start-y/--end-x/--end-y.")
        }

        if hasLegacy {
            return SwipeCoordinates(
                startX: startX!, startY: startY!,
                endX: endX!, endY: endY!
            )
        }
        if let from, let to {
            return SwipeCoordinates(startX: from.x, startY: from.y, endX: to.x, endY: to.y)
        }
        return SwipeCoordinates(
            startX: positional[0].x, startY: positional[0].y,
            endX: positional[1].x, endY: positional[1].y
        )
    }
}
