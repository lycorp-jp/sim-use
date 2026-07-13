// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation

/// Shared targeting flag surface of the tap family (`tap`,
/// `long-press`, `ios tap`): explicit coordinates, the five
/// accessibility selectors, and the type / frame disambiguators.
/// Declared once so every surface parses identically and the top-level
/// forwarders transfer the whole parsed group instead of copying
/// fields one by one (#42).
///
/// Two tap-family flags deliberately stay per-command: the positional
/// alias (its help text names the verb) and `--duration` (different
/// default and help between `tap` and `long-press`).
public struct TapTargetingOptions: ParsableArguments {
    @Option(name: [.customShort("x"), .customLong("x")], help: "The X coordinate of the target point. Accepts -x or --x.")
    public var pointX: Double?

    @Option(name: [.customShort("y"), .customLong("y")], help: "The Y coordinate of the target point. Accepts -y or --y.")
    public var pointY: Double?

    @Option(name: .customLong("point"), help: ArgumentHelp(
        "The target point as a coordinate pair — same semantics as -x/-y; specify only one form.",
        valueName: "x,y"
    ))
    public var point: CoordinatePair?

    @Option(name: [.customLong("id")], help: "Target the center of the element matching AXUniqueId/resource-id literally. For the N-th outline entry, use the positional `@N` alias instead — `--id 42` matches the identifier string '42', NOT outline alias @42. Ignored if explicit coordinates (-x/-y or --point) are provided.")
    public var elementID: String?

    @Option(name: [.customLong("label")], help: "Target the center of the element matching AXLabel (accessibilityLabel). Ignored if explicit coordinates (-x/-y or --point) are provided.")
    public var elementLabel: String?

    @Option(name: [.customLong("value")], help: "Target the center of the element matching AXValue (the current value of a control). Ignored if explicit coordinates (-x/-y or --point) are provided.")
    public var elementValue: String?

    @Option(name: [.customLong("label-contains")], help: "Target the element whose AXLabel contains this case-sensitive substring. Useful when labels carry dynamic state (counters, timestamps). Mutually exclusive with --id/--label/--value/--label-regex.")
    public var labelContains: String?

    @Option(name: [.customLong("label-regex")], help: "Target the element whose AXLabel matches this ICU regex. Anchor with ^/$ for exact match. Mutually exclusive with --id/--label/--value/--label-contains.")
    public var labelRegex: String?

    @Option(name: [.customLong("element-type")], help: "Filter matches to elements of this accessibility type (e.g. Button, TextField, Switch). Narrows --id/--label/--value/--label-contains/--label-regex results when multiple elements match.")
    public var elementType: String?

    @Option(
        name: .customLong("frame"),
        parsing: .singleValue,
        help: ArgumentHelp(
            "Geometric AND-filter on frame bounds. Repeatable. Each value is a comma-separated list of `key=value` pairs. Keys: minX, maxX, minY, maxY. Values are absolute pixels (e.g. 700) or 0..1 fractions of the screen with an `r` suffix (e.g. 0.6r). Combine with selectors to disambiguate when several elements share a label/pattern but live in different screen regions.",
            valueName: "key=value[,key=value]"
        )
    )
    public var frameSpecs: [String] = []

    public init() {}

    /// Shared targeting rules for every tap-family surface. Not the
    /// `ParsableArguments.validate()` witness — ArgumentParser (1.5.0)
    /// does not auto-validate nested option groups, and the
    /// alias-conflict rules need the per-command positional, so each
    /// command calls this explicitly from its own `validate()` (the
    /// same convention `MultiTouchOptions.validate()` uses).
    public func validate(alias: String?) throws {
        if let alias {
            guard OutlineAliasResolver.looksLikeAlias(alias) else {
                throw ValidationError("Positional alias '\(alias)' must be `@N`, `#N`, `#N@M`, or `#<identifier>`.")
            }
            var conflicts: [String] = []
            if pointX != nil { conflicts.append("-x") }
            if pointY != nil { conflicts.append("-y") }
            if point != nil { conflicts.append("--point") }
            if elementID != nil { conflicts.append("--id") }
            if elementLabel != nil { conflicts.append("--label") }
            if elementValue != nil { conflicts.append("--value") }
            if labelContains != nil { conflicts.append("--label-contains") }
            if labelRegex != nil { conflicts.append("--label-regex") }
            if !conflicts.isEmpty {
                throw ValidationError("Alias '\(alias)' cannot be combined with \(conflicts.joined(separator: ", ")).")
            }
        } else if pointX != nil || pointY != nil || point != nil {
            _ = try TapCoordinateResolver.resolve(x: pointX, y: pointY, point: point)
        } else {
            let selectors: [(String, String?)] = [
                ("--id", elementID),
                ("--label", elementLabel),
                ("--value", elementValue),
                ("--label-contains", labelContains),
                ("--label-regex", labelRegex),
            ]
            let provided = selectors.filter { $0.1 != nil }
            if provided.isEmpty {
                throw ValidationError("Either provide an `@N` / `#N` / `#N@M` alias, coordinates (--point x,y or both -x/-y), or use --id/--label/--value/--label-contains/--label-regex to tap an element.")
            }
            if provided.count > 1 {
                let names = provided.map(\.0).joined(separator: ", ")
                throw ValidationError("Use only one of --id, --label, --value, --label-contains, --label-regex (got: \(names)).")
            }
            for (name, raw) in provided {
                if let raw, raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ValidationError("\(name) must not be empty.")
                }
            }
            if let labelRegex {
                do {
                    _ = try NSRegularExpression(pattern: labelRegex, options: [])
                } catch {
                    throw ValidationError("--label-regex '\(labelRegex)' is not a valid regular expression: \(error.localizedDescription)")
                }
            }
        }

        if !frameSpecs.isEmpty {
            // `SelectorFrameFilter` mirrors the iOS-side
            // `AccessibilityTargetResolver.FrameFilter` spec syntax and
            // error messages verbatim, so validating here keeps the
            // user-facing text identical while staying platform-neutral.
            do {
                _ = try SelectorFrameFilter(specs: frameSpecs)
            } catch let error as SelectorFrameFilter.ParseError {
                throw ValidationError(error.message)
            }

            if pointX != nil || pointY != nil || point != nil {
                throw ValidationError("--frame cannot be combined with explicit -x/-y/--point coordinates (those bypass the AX tree).")
            }
            if let alias, case .some(let parsed) = OutlineAliasResolver.parse(alias) {
                switch parsed {
                case .at, .list:
                    throw ValidationError("--frame cannot be combined with the @N / #N / #N@M alias forms (they resolve to cached coordinates without consulting the AX tree). Use --label / --label-contains / --label-regex / --id / #<id> with --frame instead.")
                case .id:
                    break
                }
            }
        }
    }

    /// True when explicit coordinates were provided in either form.
    public var hasExplicitCoordinates: Bool {
        pointX != nil || pointY != nil || point != nil
    }
}
