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
}
