// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore
import Testing

struct StandardInputTextTests {
    @Test(arguments: ["", "\n--token 🐈\r\n\n", "  spaced  ", "\u{FEFF}token"])
    func preservesUTF8(_ text: String) throws {
        let input = Pipe()
        try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try input.fileHandleForWriting.close()
        let decoded = try StandardInputText.read(from: input.fileHandleForReading)
        #expect(Array(decoded.utf8) == Array(text.utf8))
    }

    @Test func rejectsInvalidUTF8() throws {
        let input = Pipe()
        try input.fileHandleForWriting.write(contentsOf: Data([0x61, 0xff]))
        try input.fileHandleForWriting.close()
        #expect(throws: CLIError.self) { try StandardInputText.read(from: input.fileHandleForReading) }
    }
}
