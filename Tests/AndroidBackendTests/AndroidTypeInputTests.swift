// SPDX-License-Identifier: Apache-2.0
import AndroidBackend
import Foundation
import Testing

struct AndroidTypeInputTests {
    @Test("Explicit Android type accepts exactly one text source")
    func androidSources() throws {
        let command = try AndroidTypeCommand.parse(["--stdin", "--clear"])
        #expect(command.clear)
        #expect(throws: (any Error).self) { try AndroidTypeCommand.parse([]) }
        #expect(throws: (any Error).self) { try AndroidTypeCommand.parse(["text", "--stdin"]) }
        let data = try JSONEncoder().encode(AndroidTypeCommand.ExecutionResult())
        #expect(String(decoding: data, as: UTF8.self) == "{}")
    }

    @Test(arguments: ["--clear", "-", "--", "", "\n--x 🐈\r\n", "--device=other", "a b"])
    func forwardsResolvedStdinAsOnePositional(_ text: String) throws {
        for terminator in [[], ["--"]] {
            let arguments = ["--device", "emulator-5554", "--stdin", "--clear"] + terminator
            var client = try AndroidTypeCommand.parse(arguments)
            client.text = text  // State after client-side stdin resolution.
            let forwarded = try client.daemonArguments(from: ["android", "type"] + arguments)
            #expect(forwarded == ["android", "type", "--device", "emulator-5554", "--clear", "--", text])
            let daemon = try AndroidTypeCommand.parse(Array(forwarded.dropFirst(2)))
            #expect(daemon.text == text)
            #expect(daemon.clear)
            #expect(!daemon.useStdin)
        }
    }
}
