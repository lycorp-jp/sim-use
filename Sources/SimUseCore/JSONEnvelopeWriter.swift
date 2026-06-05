// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Canonical writer for the `sim-use` `--json` envelope. One shape on
/// success (`{ok: true, data: ...}`) and one on failure
/// (`{ok: false, error: "...", hint: "..."?}`), compact + sorted keys
/// so downstream `jq` / LLM pipelines see a stable schema regardless
/// of which CLI surface produced the output (top-level cross-platform
/// verb, `sim-use ios <verb>`, or `sim-use android <verb>`).
///
/// Backends that conform to `SimUseExecutableCommand` get this for
/// free through the protocol-default `run()`. Android verbs are bare
/// `ParsableCommand`s (the daemon path is iOS-only) and call into
/// this writer directly from their own `run()`.
public enum JSONEnvelopeWriter {
    /// Emit `{ok: true, data: <payload>}` followed by a single LF.
    /// When `advisory` carries process-liveness events it nests under
    /// the `process` key (issue #81); a nil / empty advisory is omitted
    /// so the baseline envelope shape is unchanged.
    public static func writeSuccess<T: Encodable>(
        _ data: T,
        advisory: ProcessAdvisory? = nil,
        to handle: FileHandle = .standardOutput
    ) throws {
        let encoded = try makeEncoder().encode(SuccessEnvelope(data: data, process: nonEmpty(advisory)))
        handle.write(encoded)
        handle.write(Data([0x0A]))
    }

    /// Emit `{ok: false, error: "...", hint?: "..."}` followed by a
    /// single LF. `hint` is omitted when the error does not conform
    /// to `HintProviding`. The encode itself cannot fail in practice
    /// (Encodable strings always succeed), but stays non-throwing so
    /// callers can use it inside their own `catch` blocks without
    /// nesting another `do`.
    public static func writeError(
        _ error: Error,
        to handle: FileHandle = .standardOutput
    ) {
        let envelope = ErrorEnvelope(
            error: error.localizedDescription,
            hint: (error as? HintProviding)?.hint
        )
        guard let encoded = try? makeEncoder().encode(envelope) else { return }
        handle.write(encoded)
        handle.write(Data([0x0A]))
    }

    /// Direct access for callers that need the encoded bytes without
    /// writing to a `FileHandle` (used by tests to snapshot the wire
    /// shape).
    public static func encodeSuccess<T: Encodable>(_ data: T, advisory: ProcessAdvisory? = nil) throws -> Data {
        try makeEncoder().encode(SuccessEnvelope(data: data, process: nonEmpty(advisory)))
    }

    /// Drop an empty advisory so the `process` key never appears with no
    /// content.
    private static func nonEmpty(_ advisory: ProcessAdvisory?) -> ProcessAdvisory? {
        guard let advisory, !advisory.isEmpty else { return nil }
        return advisory
    }

    /// Direct access for tests; see `encodeSuccess`.
    public static func encodeError(_ error: Error) throws -> Data {
        let envelope = ErrorEnvelope(
            error: error.localizedDescription,
            hint: (error as? HintProviding)?.hint
        )
        return try makeEncoder().encode(envelope)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private struct SuccessEnvelope<T: Encodable>: Encodable {
    let ok: Bool = true
    let data: T
    let process: ProcessAdvisory?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encode(data, forKey: .data)
        if let process { try container.encode(process, forKey: .process) }
    }

    private enum CodingKeys: String, CodingKey { case ok, data, process }
}

private struct ErrorEnvelope: Encodable {
    let ok: Bool = false
    let error: String
    let hint: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encode(error, forKey: .error)
        if let hint { try container.encode(hint, forKey: .hint) }
    }

    private enum CodingKeys: String, CodingKey { case ok, error, hint }
}