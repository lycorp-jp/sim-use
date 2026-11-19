// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum StandardInputText {
    /// An empty pipe is valid input. Read and decoding errors must reach the
    /// caller before a replace operation can change the focused field.
    public static func read(from handle: FileHandle = .standardInput) throws -> String {
        let data = try handle.readToEnd() ?? Data()
        // Foundation's UTF-8 initializer drops a leading U+FEFF on macOS.
        // A round trip preserves it and detects replacement of invalid bytes.
        let text = String(decoding: data, as: UTF8.self)
        guard text.utf8.elementsEqual(data) else {
            throw CLIError(errorDescription: "Standard input must contain valid UTF-8 text.")
        }
        return text
    }
}
