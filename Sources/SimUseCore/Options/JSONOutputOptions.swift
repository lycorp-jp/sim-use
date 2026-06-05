// SPDX-License-Identifier: Apache-2.0
import ArgumentParser

/// Shared `--json` flag declaration. Every `SimUseExecutableCommand`
/// previously carried its own
/// `@Flag(name: .customLong("json")) public var jsonOutput: Bool = false`;
/// pulling them into a single group keeps help text and default
/// behaviour consistent across the surface.
///
/// Adopt with `@OptionGroup public var json: JSONOutputOptions`. The
/// protocol's `jsonOutput` requirement becomes
/// `public var jsonOutput: Bool { json.enabled }` on the conforming
/// command.
public struct JSONOutputOptions: ParsableArguments {
    @Flag(
        name: .customLong("json"),
        help: "Emit the result as compact JSON instead of the human-readable success line."
    )
    public var enabled: Bool = false

    public init() {}
}