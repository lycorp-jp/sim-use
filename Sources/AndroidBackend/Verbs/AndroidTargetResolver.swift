// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// Parses an `"x,y"` coordinate string into an integer point. Used by
/// the `--from` / `--to` / `--center` flags on the Android swipe and
/// scroll commands. Module-internal so the Swift access level keeps
/// the helper out of the public API surface.
func parsePoint(_ raw: String, flag: String) throws -> (Int, Int) {
    let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 2,
          let x = Int(parts[0]),
          let y = Int(parts[1])
    else {
        throw ValidationError("\(flag) must be in the form x,y (integers, pixels)")
    }
    return (x, y)
}

/// Resolves a tap target either by alias (`@N`/`#N`/`#<id>`),
/// coordinate (`-x`/`-y`), or selector flags. Selector and alias paths
/// share the `OutlineCache` from the most recent `describe-ui` so they
/// stay stateless across CLI invocations.
public enum AndroidTargetResolver {

    public struct Target {
        public let x: Int
        public let y: Int
        public let description: String
    }

    public enum ResolveError: LocalizedError, Equatable {
        case noAddress

        public var errorDescription: String? {
            switch self {
            case .noAddress:
                return "Need at least one of: positional alias (@N / #N), -x/-y coordinate, or a selector flag (--id/--label/--value/…)."
            }
        }
    }

    public static func resolve(
        udid: String,
        alias: String?,
        x: Int?, y: Int?,
        selector: AndroidSelector,
        controller: AndroidDeviceController
    ) throws -> Target {
        if let x, let y {
            return Target(x: x, y: y, description: "coord")
        }

        if let alias, !alias.isEmpty {
            // Cache-backed forms (@N / #N / #N@M) and the `#<id>` live
            // form share one entry point — `OutlineAliasResolver.resolve`
            // (which already powers the iOS side) classifies the alias
            // and either returns the cached center point or signals
            // `.idNotCacheable` for `#<id>`. Catching that one case lets
            // us route uniqueId aliases through a fresh describe-ui
            // without re-implementing the rest of the parser/cache
            // pipeline. All list-aware error shapes
            // (atOutOfRange / listScopeOutOfRange / listIndexOutOfRange /
            // listUnsupported) come through verbatim — Android now
            // surfaces the same "Snapshot has list scopes @1..@N" and
            // "Dominant list has cells #1..#N" messages iOS has had
            // since the cache was introduced.
            do {
                let resolved = try OutlineAliasResolver.resolve(alias, udid: udid)
                return Target(
                    x: Int(resolved.point.x.rounded()),
                    y: Int(resolved.point.y.rounded()),
                    description: "alias \(alias) → \(resolved.role) \"\(resolved.label)\""
                )
            } catch OutlineAliasResolver.ResolutionError.idNotCacheable(let uniqueId) {
                let result = try controller.describeUI(serial: udid)
                return try resolveIDAlias(
                    uniqueId: uniqueId,
                    selector: selector,
                    entries: result.entries,
                    screen: result.screen
                )
            }
        }

        if !selector.isEmpty {
            // Drive a fresh describe-ui so selector matches against the
            // current screen (cache may be stale). The `screen` field
            // doubles as the reference frame for resolving relative
            // bounds in `selector.frame` — `minY=0.5r` on a 2400-tall
            // display means "y ≥ 1200" only once we know the height.
            let result = try controller.describeUI(serial: udid)
            let entry = try AndroidSelectorResolver.resolve(
                selector: selector,
                entries: result.entries,
                screen: result.screen
            )
            let cx = entry.frame.x + entry.frame.width / 2
            let cy = entry.frame.y + entry.frame.height / 2
            return Target(x: cx, y: cy, description: "selector → \(entry.role) \"\(entry.label)\"")
        }

        throw ResolveError.noAddress
    }

    /// Pure-data helper for the `#<id>` alias path so it can be unit
    /// tested without spinning up an `AndroidDeviceController`. The
    /// caller (the live `resolve(...)` above) fetches `entries` /
    /// `screen` from a fresh describe-ui; tests plant a synthetic list.
    /// Layering `uniqueId` onto the caller's selector preserves any
    /// `--element-type` / `--frame` narrowers passed alongside the
    /// alias — same shape as iOS's `IOSSimTapCommand` `.id` branch.
    static func resolveIDAlias(
        uniqueId: String,
        selector: AndroidSelector,
        entries: [Outline.Entry],
        screen: Outline.Frame?
    ) throws -> Target {
        var idSelector = selector
        idSelector.id = uniqueId
        let entry = try AndroidSelectorResolver.resolve(
            selector: idSelector,
            entries: entries,
            screen: screen
        )
        let cx = entry.frame.x + entry.frame.width / 2
        let cy = entry.frame.y + entry.frame.height / 2
        return Target(
            x: cx,
            y: cy,
            description: "alias #\(uniqueId) → \(entry.role) \"\(entry.label)\""
        )
    }

}