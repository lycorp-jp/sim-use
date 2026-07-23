// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import AndroidBackend
import Foundation
import SimUseCore
import Testing

/// Pins the `--no-raw` contract on `describe-ui`: the flag parses on
/// all three command surfaces, the top-level forwarder copies it, and
/// an `ExecutionResult` built without a raw tree encodes an envelope
/// with no `raw` key at all (rather than `"raw": null`).
@Suite("describe-ui --no-raw")
struct DescribeUINoRawTests {
    private let iosUDID = "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0"

    @Test("top-level forwarder copies --no-raw to the iOS backend command")
    func forwarderCopiesNoRaw() throws {
        let on = try DescribeUI.parse(["--udid", iosUDID, "--json", "--no-raw"])
        #expect(on.makeIOSSubcommand().noRaw)

        let off = try DescribeUI.parse(["--udid", iosUDID, "--json"])
        #expect(!off.makeIOSSubcommand().noRaw)
    }

    @Test("iOS and Android backend commands accept --no-raw")
    func backendCommandsParseNoRaw() throws {
        let ios = try IOSSimDescribeUICommand.parse(["--udid", iosUDID, "--json", "--no-raw"])
        #expect(ios.noRaw)

        let android = try AndroidDescribeUICommand.parse(["--device", "emulator-5554", "--json", "--no-raw"])
        #expect(android.noRaw)
    }

    @Test("ExecutionResult omits the raw key when the tree was not built")
    func encodingOmitsRawKey() throws {
        func encode(raw: JSONValue?) throws -> String {
            let result = IOSSimDescribeUICommand.ExecutionResult(
                platform: "ios",
                raw: raw,
                outline: "App: Demo  200x400\n",
                entries: [],
                lists: [],
                screen: Outline.Frame(x: 0, y: 0, width: 200, height: 400),
                appLabel: "Demo",
                appPackage: "com.example.demo"
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(result), as: UTF8.self)
        }

        let withRaw = try encode(raw: .object(["type": .string("Application")]))
        #expect(withRaw.contains("\"raw\""))

        let withoutRaw = try encode(raw: nil)
        #expect(!withoutRaw.contains("\"raw\""))
    }
}
