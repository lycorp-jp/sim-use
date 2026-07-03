// SPDX-License-Identifier: Apache-2.0
import ArgumentParser

/// Shared swipe coordinate flag declaration consumed by the top-level
/// `swipe`, `ios swipe`, and `android swipe` commands. Centralised so
/// the three accepted forms — positional `<x,y> <x,y>`, `--from/--to`
/// pairs, and the four legacy `--start-x/--start-y/--end-x/--end-y`
/// flags — plus their exclusivity and range rules stay in lockstep
/// across every surface. Mirrors `MultiTouchOptions`.
public struct SwipeCoordinateOptions: ParsableArguments {
    @Argument(help: ArgumentHelp(
        "Optional positional coordinate pairs: <from x,y> <to x,y>. Exclusive with --from/--to and --start-x/--start-y/--end-x/--end-y.",
        valueName: "x,y"
    ))
    public var coordinatePairs: [CoordinatePair] = []

    @Option(name: .customLong("from"), help: ArgumentHelp("Starting coordinate pair.", valueName: "x,y"))
    public var from: CoordinatePair?

    @Option(name: .customLong("to"), help: ArgumentHelp("Ending coordinate pair.", valueName: "x,y"))
    public var to: CoordinatePair?

    @Option(name: .customLong("start-x"), help: "The X coordinate of the starting point.")
    public var startX: Double?

    @Option(name: .customLong("start-y"), help: "The Y coordinate of the starting point.")
    public var startY: Double?

    @Option(name: .customLong("end-x"), help: "The X coordinate of the ending point.")
    public var endX: Double?

    @Option(name: .customLong("end-y"), help: "The Y coordinate of the ending point.")
    public var endY: Double?

    public init() {}

    /// Resolve whichever complete form was supplied into concrete
    /// coordinates. Throws `ValidationError` for missing/partial/mixed
    /// forms and for out-of-range values (negative, non-finite, or
    /// absurdly large). Commands call this from `validate()` so errors
    /// fire at parse time, and again from `execute()` to obtain the
    /// values.
    public func resolve() throws -> SwipeCoordinates {
        try SwipeCoordinateResolver.resolve(
            startX: startX, startY: startY,
            endX: endX, endY: endY,
            from: from, to: to,
            positional: coordinatePairs
        )
    }
}
