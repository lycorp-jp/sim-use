// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import ArgumentParser
import Foundation
import Testing
@testable import SimUseCore

/// Helper that fully parses + validates a Tap invocation. We rely on the
/// `parseAsRoot` path because that's exactly how the CLI and `BatchStepParser`
/// reach the command, including the embedded `validate()` call.
private func tryParseTap(_ args: [String]) throws -> Tap {
    let full = args + ["--udid", "FAKE-UDID"]
    guard let parsed = try Tap.parseAsRoot(full) as? Tap else {
        throw CLIError(errorDescription: "Failed to cast parsed command")
    }
    return parsed
}

@Suite("Tap selector validation")
struct TapValidationTests {
    @Test("--label-contains alone validates")
    func labelContainsAlone() throws {
        #expect(throws: Never.self) {
            _ = try tryParseTap(["--label-contains", "Submit"])
        }
    }

    @Test("--label-regex alone validates")
    func labelRegexAlone() throws {
        #expect(throws: Never.self) {
            _ = try tryParseTap(["--label-regex", "^Submit$"])
        }
    }

    @Test("valid ICU regex with character classes parses")
    func validIcuRegex() throws {
        #expect(throws: Never.self) {
            _ = try tryParseTap(["--label-regex", #"^[A-Za-z]+-\d+$"#])
        }
    }

    @Test("--label-contains together with --label-regex is rejected")
    func containsAndRegexConflict() throws {
        #expect(throws: (any Error).self) {
            _ = try tryParseTap(["--label-contains", "x", "--label-regex", "^x$"])
        }
    }

    @Test("--label-contains together with --label is rejected")
    func containsAndLabelConflict() throws {
        #expect(throws: (any Error).self) {
            _ = try tryParseTap(["--label-contains", "x", "--label", "x"])
        }
    }

    @Test("--label-regex together with --id is rejected")
    func regexAndIdConflict() throws {
        #expect(throws: (any Error).self) {
            _ = try tryParseTap(["--label-regex", "^x$", "--id", "btn"])
        }
    }

    @Test("alias plus --label-contains is rejected")
    func aliasPlusContainsConflict() throws {
        #expect(throws: (any Error).self) {
            _ = try tryParseTap(["@1", "--label-contains", "x"])
        }
    }

    @Test("alias plus --label-regex is rejected")
    func aliasPlusRegexConflict() throws {
        #expect(throws: (any Error).self) {
            _ = try tryParseTap(["@1", "--label-regex", "^x$"])
        }
    }

    @Test("empty --label-contains is rejected")
    func emptyContains() throws {
        #expect(throws: (any Error).self) {
            _ = try tryParseTap(["--label-contains", "  "])
        }
    }

    @Test("empty --label-regex is rejected")
    func emptyRegex() throws {
        #expect(throws: (any Error).self) {
            _ = try tryParseTap(["--label-regex", "   "])
        }
    }

    @Test("invalid regex is rejected at validation time")
    func invalidRegex() throws {
        do {
            _ = try tryParseTap(["--label-regex", "(unclosed"])
            Issue.record("Expected validation error")
        } catch {
            // ArgumentParser wraps validate() errors in a CommandError; we just
            // confirm the diagnostic mentions the offending pattern so a user
            // running the CLI would see it.
            let message = String(describing: error)
            #expect(message.contains("(unclosed"))
            #expect(message.contains("--label-regex"))
        }
    }
}

@Suite("Tap --frame validation")
struct TapFrameValidationTests {
    @Test("--frame with absolute key=value parses")
    func absSinglePair() throws {
        #expect(throws: Never.self) {
            _ = try tryParseTap(["--label", "Submit", "--frame", "minY=700"])
        }
    }

    @Test("--frame with relative key=value parses")
    func relSinglePair() throws {
        #expect(throws: Never.self) {
            _ = try tryParseTap(["--label", "Submit", "--frame", "minY=0.6r"])
        }
    }

    @Test("--frame with multi-pair single value parses")
    func multiPairSingleFlag() throws {
        #expect(throws: Never.self) {
            _ = try tryParseTap(["--label", "Submit", "--frame", "minY=0.7r,maxY=1.0r"])
        }
    }

    @Test("--frame can be specified multiple times")
    func repeatedFlagAcccumulates() throws {
        #expect(throws: Never.self) {
            _ = try tryParseTap(["--label", "Submit", "--frame", "minY=700", "--frame", "maxX=200"])
        }
    }

    @Test("--frame composes with --label-contains")
    func composesWithLabelContains() throws {
        #expect(throws: Never.self) {
            _ = try tryParseTap(["--label-contains", "トーク", "--frame", "minY=0.7r"])
        }
    }

    @Test("--frame unknown key is rejected at validation time")
    func unknownKeyRejected() throws {
        do {
            _ = try tryParseTap(["--label", "Submit", "--frame", "width=10"])
            Issue.record("Expected validation error")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("unknown"))
            #expect(message.contains("width"))
        }
    }

    @Test("--frame duplicate key across flags is rejected")
    func duplicateAcrossFlags() throws {
        do {
            _ = try tryParseTap(["--label", "Submit", "--frame", "minY=700", "--frame", "minY=200"])
            Issue.record("Expected validation error")
        } catch {
            #expect(String(describing: error).contains("more than once"))
        }
    }

    @Test("--frame relative value above 1 is rejected")
    func relAboveOneRejected() throws {
        do {
            _ = try tryParseTap(["--label", "Submit", "--frame", "minY=1.5r"])
            Issue.record("Expected validation error")
        } catch {
            #expect(String(describing: error).contains("0…1"))
        }
    }

    @Test("--frame minX > maxX rejected")
    func swappedBoundsRejected() throws {
        do {
            _ = try tryParseTap(["--label", "Submit", "--frame", "minX=300,maxX=10"])
            Issue.record("Expected validation error")
        } catch {
            #expect(String(describing: error).contains("≤"))
        }
    }

    @Test("--frame combined with -x/-y is rejected")
    func frameWithExplicitCoordsRejected() throws {
        do {
            _ = try tryParseTap(["-x", "100", "-y", "200", "--frame", "minY=0.5r"])
            Issue.record("Expected validation error")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("--frame"))
            #expect(message.contains("-x"))
        }
    }

    @Test("--frame combined with @N alias is rejected")
    func frameWithAtAliasRejected() throws {
        do {
            _ = try tryParseTap(["@5", "--frame", "minY=0.5r"])
            Issue.record("Expected validation error")
        } catch {
            #expect(String(describing: error).contains("@N"))
        }
    }

    @Test("--frame combined with #N alias is rejected")
    func frameWithListAliasRejected() throws {
        do {
            _ = try tryParseTap(["#3", "--frame", "minY=0.5r"])
            Issue.record("Expected validation error")
        } catch {
            #expect(String(describing: error).contains("@N"))
        }
    }

    @Test("--frame combined with #<id> alias is allowed (live AX path)")
    func frameWithIdAliasAllowed() throws {
        #expect(throws: Never.self) {
            _ = try tryParseTap(["#someButton", "--frame", "minY=0.5r"])
        }
    }
}