// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

// Pins the CommandAdvisoryProviding exclude-from-data contract for every
// conformer: the envelope hoists `commandAdvisory` to the top-level
// `advisory` key, so a result type that also encoded the advisory inside
// its own payload would silently duplicate it on the wire (and leak an
// object no client schema expects). Nothing enforces the exclusion at
// compile time — new conformers must register here.

private let contractAdvisory = CommandAdvisory(kind: .fullScreenTapTarget, message: "check target")

private func encodedJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

@Suite("CommandAdvisoryProviding — exclude-from-data contract")
struct CommandAdvisoryContractTests {
    @Test("tap result encodes without the advisory and decodes it as nil")
    func tapResult() throws {
        let result = IOSSimTapCommand.ExecutionResult(x: 10, y: 20, commandAdvisory: contractAdvisory)
        #expect(result.commandAdvisory == contractAdvisory)

        let json = try encodedJSON(result)
        #expect(json == #"{"x":10,"y":20}"#)

        let decoded = try JSONDecoder().decode(IOSSimTapCommand.ExecutionResult.self, from: Data(json.utf8))
        #expect(decoded.commandAdvisory == nil)
        #expect(decoded.x == 10)
        #expect(decoded.y == 20)
    }

    @Test("batch result encodes without the advisory and decodes it as nil")
    func batchResult() throws {
        let result = IOSSimBatchCommand.ExecutionResult(stepsExecuted: 3, commandAdvisory: contractAdvisory)
        #expect(result.commandAdvisory == contractAdvisory)

        let json = try encodedJSON(result)
        #expect(json == #"{"stepsExecuted":3}"#)

        let decoded = try JSONDecoder().decode(IOSSimBatchCommand.ExecutionResult.self, from: Data(json.utf8))
        #expect(decoded.commandAdvisory == nil)
        #expect(decoded.stepsExecuted == 3)
    }

    @Test("describe-ui result encodes without the advisory and decodes it as nil")
    func describeUIResult() throws {
        let result = IOSSimDescribeUICommand.ExecutionResult(
            platform: "ios",
            raw: nil,
            outline: "App: X  10x20\n",
            entries: [],
            lists: [],
            screen: .init(x: 0, y: 0, width: 10, height: 20),
            appLabel: "X",
            appPackage: "com.x",
            orientation: "portrait-upside-down",
            commandAdvisory: contractAdvisory
        )
        #expect(result.commandAdvisory == contractAdvisory)

        let json = try encodedJSON(result)
        #expect(!json.contains("dvisory"), "advisory leaked into the encoded data payload: \(json)")
        #expect(json.contains(#""orientation":"portrait-upside-down""#))

        let decoded = try JSONDecoder().decode(IOSSimDescribeUICommand.ExecutionResult.self, from: Data(json.utf8))
        #expect(decoded.commandAdvisory == nil)
        #expect(decoded.orientation == "portrait-upside-down")
        #expect(decoded.appLabel == "X")
    }
}
