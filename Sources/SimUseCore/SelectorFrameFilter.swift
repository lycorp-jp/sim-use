// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Geometric AND-filter on accessibility-tree entries' bounding boxes.
///
/// Used to disambiguate selector matches that share a label / value but
/// live in different screen regions (e.g. the same "Notifications"
/// label appearing on both a settings row and a confirmation popup at
/// the bottom of the screen). Mirrors the iOS-side
/// `AccessibilityTargetResolver.FrameFilter` and shares its spec
/// syntax — `--frame minY=700`, `--frame minY=0.5r,maxX=0.9r`.
///
/// The parsed filter still carries relative bounds (the `*Rel` fields);
/// `resolved(screen:)` converts them to absolute pixels against a
/// concrete screen frame for the actual `contains(_:)` check. This is
/// the same two-phase shape iOS uses so the spec layer can be parsed
/// before any device is involved and the resolution layer can happen
/// per-screen.
public struct SelectorFrameFilter: Sendable, Equatable {
    public var minX: Double?
    public var maxX: Double?
    public var minY: Double?
    public var maxY: Double?
    public var minXRel: Double?
    public var maxXRel: Double?
    public var minYRel: Double?
    public var maxYRel: Double?

    public init(
        minX: Double? = nil, maxX: Double? = nil,
        minY: Double? = nil, maxY: Double? = nil,
        minXRel: Double? = nil, maxXRel: Double? = nil,
        minYRel: Double? = nil, maxYRel: Double? = nil
    ) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
        self.minXRel = minXRel
        self.maxXRel = maxXRel
        self.minYRel = minYRel
        self.maxYRel = maxYRel
    }

    public var isEmpty: Bool {
        minX == nil && maxX == nil && minY == nil && maxY == nil &&
        minXRel == nil && maxXRel == nil && minYRel == nil && maxYRel == nil
    }

    public var hasRelativeBounds: Bool {
        minXRel != nil || maxXRel != nil || minYRel != nil || maxYRel != nil
    }

    /// Resolves relative bounds against a concrete screen frame,
    /// returning an all-absolute filter ready for per-element checks.
    public func resolved(screen: Outline.Frame) -> SelectorFrameFilter {
        var copy = self
        let sx = Double(screen.x), sy = Double(screen.y)
        let sw = Double(screen.width), sh = Double(screen.height)
        if let r = minXRel { copy.minX = sx + r * sw; copy.minXRel = nil }
        if let r = maxXRel { copy.maxX = sx + r * sw; copy.maxXRel = nil }
        if let r = minYRel { copy.minY = sy + r * sh; copy.minYRel = nil }
        if let r = maxYRel { copy.maxY = sy + r * sh; copy.maxYRel = nil }
        return copy
    }

    /// True iff `frame`'s top-left corner satisfies every set bound.
    /// Bounds compare against the entry's `x`/`y` (top-left), not the
    /// center, so a `minY=500` band selects entries that *start* below
    /// 500 — the natural reading of "below this y line".
    public func contains(_ frame: Outline.Frame) -> Bool {
        let x = Double(frame.x), y = Double(frame.y)
        if let lo = minX, x < lo { return false }
        if let hi = maxX, x > hi { return false }
        if let lo = minY, y < lo { return false }
        if let hi = maxY, y > hi { return false }
        return true
    }

    public struct ParseError: Error, Equatable {
        public let message: String
        public init(message: String) { self.message = message }
    }

    /// Parse one or more `--frame key=value[,key=value]` strings into a
    /// `SelectorFrameFilter`. Numeric values are absolute pixels;
    /// suffixing `r` marks the value as a 0…1 fraction of the screen.
    ///
    /// Same key set twice (across or within `--frame` flags) is an
    /// error. Mixing absolute and relative on the same axis bound
    /// (e.g. `minY=700` plus `minY=0.6r`) is also caught — callers
    /// should pick one form per bound.
    public init(specs: [String]) throws {
        self.init()
        var seen: Set<String> = []
        for spec in specs {
            let pairs = spec.split(separator: ",", omittingEmptySubsequences: false)
            for raw in pairs {
                let pair = raw.trimmingCharacters(in: .whitespaces)
                guard !pair.isEmpty else {
                    throw ParseError(message: "--frame entry is empty (check for stray commas in '\(spec)').")
                }
                guard let eq = pair.firstIndex(of: "=") else {
                    throw ParseError(message: "--frame entry '\(pair)' must be 'key=value' (e.g. minY=700 or minY=0.6r).")
                }
                let key = String(pair[..<eq]).trimmingCharacters(in: .whitespaces)
                let valueRaw = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                guard Self.knownKeys.contains(key) else {
                    throw ParseError(message: "--frame key '\(key)' is unknown. Valid keys: \(Self.knownKeys.sorted().joined(separator: ", ")).")
                }
                guard !seen.contains(key) else {
                    throw ParseError(message: "--frame key '\(key)' was specified more than once.")
                }
                seen.insert(key)
                let (number, isRelative) = try Self.parseNumber(valueRaw, key: key)
                if isRelative {
                    guard number >= 0, number <= 1 else {
                        throw ParseError(message: "--frame \(key)=\(valueRaw): relative value must be in 0…1.")
                    }
                }
                Self.assign(&self, key: key, value: number, relative: isRelative)
            }
        }
        if let lo = minX, let hi = maxX, lo > hi {
            throw ParseError(message: "--frame minX (\(lo)) must be ≤ maxX (\(hi)).")
        }
        if let lo = minY, let hi = maxY, lo > hi {
            throw ParseError(message: "--frame minY (\(lo)) must be ≤ maxY (\(hi)).")
        }
        if let lo = minXRel, let hi = maxXRel, lo > hi {
            throw ParseError(message: "--frame minX (\(lo)r) must be ≤ maxX (\(hi)r).")
        }
        if let lo = minYRel, let hi = maxYRel, lo > hi {
            throw ParseError(message: "--frame minY (\(lo)r) must be ≤ maxY (\(hi)r).")
        }
    }

    private static let knownKeys: Set<String> = ["minX", "maxX", "minY", "maxY"]

    private static func parseNumber(_ raw: String, key: String) throws -> (Double, Bool) {
        let isRelative = raw.hasSuffix("r")
        let numericPart = isRelative ? String(raw.dropLast()) : raw
        guard let value = Double(numericPart) else {
            throw ParseError(message: "--frame \(key)='\(raw)' is not a number (use e.g. 700 or 0.6r).")
        }
        return (value, isRelative)
    }

    private static func assign(_ filter: inout SelectorFrameFilter, key: String, value: Double, relative: Bool) {
        switch (key, relative) {
        case ("minX", false): filter.minX = value
        case ("maxX", false): filter.maxX = value
        case ("minY", false): filter.minY = value
        case ("maxY", false): filter.maxY = value
        case ("minX", true):  filter.minXRel = value
        case ("maxX", true):  filter.maxXRel = value
        case ("minY", true):  filter.minYRel = value
        case ("maxY", true):  filter.maxYRel = value
        default: break
        }
    }
}