// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SimUseCore

/// Snapshot the byte-level wire shape of the `--json` envelope. The
/// whole point of `JSONEnvelopeWriter` is that every `sim-use` surface
/// produces the same envelope; a drift here breaks `jq` / LLM
/// pipelines that pin to keys like `.ok` / `.data.platform`. If you
/// genuinely need to change the shape, update this snapshot and bump
/// the documented schema in `SimUseExecutableCommand.swift`.
@Suite("JSONEnvelopeWriter — wire shape")
struct JSONEnvelopeWriterTests {
    private struct SamplePayload: Encodable {
        let platform: String
        let visible: Bool
        let imePackage: String?
    }

    @Test("success envelope: sorted keys, compact, trailing LF on writer path")
    func successEnvelopeShape() throws {
        let payload = SamplePayload(
            platform: "android",
            visible: true,
            imePackage: "com.example.ime"
        )
        let bytes = try JSONEnvelopeWriter.encodeSuccess(payload)
        let json = try #require(String(data: bytes, encoding: .utf8))
        #expect(json == #"{"data":{"imePackage":"com.example.ime","platform":"android","visible":true},"ok":true}"#)
    }

    @Test("success envelope omits nil Optional fields (synthesised Encodable uses encodeIfPresent)")
    func successEnvelopeNilField() throws {
        let payload = SamplePayload(platform: "android", visible: false, imePackage: nil)
        let bytes = try JSONEnvelopeWriter.encodeSuccess(payload)
        let json = try #require(String(data: bytes, encoding: .utf8))
        // Swift's synthesised `encode(to:)` for `Optional<T>` calls
        // `encodeIfPresent`, so nil fields drop out of the JSON
        // instead of serialising as `null`. This matches the
        // tagged-union shape the iOS-side `ExecutionResult` produces
        // (where chromeKeyCount/imePackage/etc. are omitted on the
        // platform that didn't observe them), so an agent toggling
        // `--udid` between platforms sees a consistent "absent key
        // means N/A" contract.
        #expect(json == #"{"data":{"platform":"android","visible":false},"ok":true}"#)
    }

    @Test("success envelope carries the process advisory under `process` when present")
    func successEnvelopeWithAdvisory() throws {
        let payload = SamplePayload(platform: "ios", visible: true, imePackage: nil)
        let advisory = ProcessAdvisory(
            events: [ProcessEvent(kind: .disappeared, bundleId: "com.x", pid: 100, confidence: .high)],
            pending: []
        )
        let bytes = try JSONEnvelopeWriter.encodeSuccess(payload, processAdvisory: advisory)
        let json = try #require(String(data: bytes, encoding: .utf8))
        #expect(json == #"{"data":{"platform":"ios","visible":true},"ok":true,"process":{"events":[{"bundleId":"com.x","confidence":"high","kind":"disappeared","pid":100}],"pending":[]}}"#)
    }

    @Test("success envelope carries command advisory under `advisory` when present")
    func successEnvelopeWithCommandAdvisory() throws {
        let payload = SamplePayload(platform: "ios", visible: true, imePackage: nil)
        let advisory = CommandAdvisory(kind: .fullScreenTapTarget, message: "check target")
        let bytes = try JSONEnvelopeWriter.encodeSuccess(payload, advisory: advisory)
        let json = try #require(String(data: bytes, encoding: .utf8))
        #expect(json == #"{"advisory":{"kind":"full_screen_tap_target","message":"check target"},"data":{"platform":"ios","visible":true},"ok":true}"#)
    }

    @Test("success envelope omits `process` when advisory is nil or empty")
    func successEnvelopeAdvisoryOmitted() throws {
        let payload = SamplePayload(platform: "ios", visible: true, imePackage: nil)
        let nilCase = try JSONEnvelopeWriter.encodeSuccess(payload, processAdvisory: nil)
        #expect(try #require(String(data: nilCase, encoding: .utf8)) == #"{"data":{"platform":"ios","visible":true},"ok":true}"#)
        let emptyCase = try JSONEnvelopeWriter.encodeSuccess(payload, processAdvisory: ProcessAdvisory(events: [], pending: []))
        #expect(try #require(String(data: emptyCase, encoding: .utf8)) == #"{"data":{"platform":"ios","visible":true},"ok":true}"#)
    }

    @Test("command advisory renderer emits the client-side info line")
    func commandAdvisoryRenderer() {
        let advisory = CommandAdvisory(kind: .fullScreenTapTarget, message: "check target")
        #expect(CommandAdvisoryRenderer.banner(for: advisory) == "[i] check target")
    }

    @Test("command advisory renderer prefixes every line of a multi-line message")
    func commandAdvisoryRendererMultiLine() {
        let advisory = CommandAdvisory(kind: .fullScreenTapTarget, message: "Step 1: a\nStep 3: b")
        #expect(CommandAdvisoryRenderer.banner(for: advisory) == "[i] Step 1: a\n[i] Step 3: b")
    }

    @Test("merged advisories collapse into one line-joined advisory")
    func mergedAdvisories() {
        #expect(CommandAdvisory.merged([]) == nil)
        let single = CommandAdvisory(kind: .fullScreenTapTarget, message: "only")
        #expect(CommandAdvisory.merged([single]) == single)
        let other = CommandAdvisory(kind: .fullScreenTapTarget, message: "second")
        #expect(CommandAdvisory.merged([single, other])
            == CommandAdvisory(kind: .fullScreenTapTarget, message: "only\nsecond"))
    }

    @Test("error envelope without hint omits the hint key entirely")
    func errorEnvelopeWithoutHint() throws {
        struct PlainError: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let bytes = try JSONEnvelopeWriter.encodeError(PlainError())
        let json = try #require(String(data: bytes, encoding: .utf8))
        #expect(json == #"{"error":"boom","ok":false}"#)
    }

    @Test("error envelope with HintProviding surfaces the hint")
    func errorEnvelopeWithHint() throws {
        struct HintedError: Error, LocalizedError, HintProviding {
            var errorDescription: String? { "device not reachable" }
            var hint: String? { "run `sim-use android init --udid X` first" }
        }
        let bytes = try JSONEnvelopeWriter.encodeError(HintedError())
        let json = try #require(String(data: bytes, encoding: .utf8))
        #expect(json == #"{"error":"device not reachable","hint":"run `sim-use android init --udid X` first","ok":false}"#)
    }

    @Test("writeSuccess(_:to:) appends a trailing LF to the handle")
    func writeSuccessAppendsLF() throws {
        let pipe = Pipe()
        try JSONEnvelopeWriter.writeSuccess(
            SamplePayload(platform: "android", visible: true, imePackage: nil),
            to: pipe.fileHandleForWriting
        )
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(data.last == 0x0A)
        let body = data.dropLast()
        let json = try #require(String(data: body, encoding: .utf8))
        #expect(json == #"{"data":{"platform":"android","visible":true},"ok":true}"#)
    }

    @Test("writeError(_:to:) appends a trailing LF to the handle")
    func writeErrorAppendsLF() throws {
        struct PlainError: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let pipe = Pipe()
        JSONEnvelopeWriter.writeError(PlainError(), to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(data.last == 0x0A)
        let body = data.dropLast()
        let json = try #require(String(data: body, encoding: .utf8))
        #expect(json == #"{"error":"boom","ok":false}"#)
    }
}
