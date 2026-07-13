// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import ArgumentParser
import Foundation
import SimUseCore
import Testing

// Guards the construct-and-assign forwarder pattern (#42): a top-level
// cross-platform verb builds its iOS backend command via the empty
// `init()` and copies every parsed property by hand. A missed
// `sub.field = field` line leaves that property in ArgumentParser's
// wrapper-definition state, and the first read traps with "can't read a
// value from a parsable argument definition" — at runtime, on a device,
// where no unit test used to look.
//
// Each test parses a valid argv, calls the forwarder's
// `makeIOSSubcommand()`, and audits the result with `Mirror`: every
// ArgumentParser property wrapper must be out of definition state.
// Parsing initializes *every* wrapper (absent flags land in their
// nil/default value state), so any valid argv exercises the full copy
// surface — the audit is about wrapper state, not values. Value
// fidelity (copying from the *right* source field) stays with the
// per-verb parity tests.
//
// The audit peeks at ArgumentParser internals (`_parsedValue`, pinned
// at 1.5.0) and fails closed: an unrecognized wrapper shape or a walk
// that finds zero wrappers is a test failure, never a silent pass — an
// ArgumentParser upgrade can break this test loudly, but cannot quietly
// blind it.

/// Result of Mirror-walking a `ParsableArguments` instance.
private struct WrapperAudit {
    /// Property paths still in wrapper-definition state — reading any
    /// of these at runtime would trap.
    var uninitialized: [String] = []
    /// Paths that look like ArgumentParser wrappers but whose internals
    /// don't match the pinned 1.5.0 shape.
    var malformed: [String] = []
    /// Wrappers successfully classified; zero means the walk is blind.
    var recognized = 0

    init(of instance: Any) {
        walk(instance, path: "")
    }

    private mutating func walk(_ instance: Any, path: String) {
        for child in Mirror(reflecting: instance).children {
            guard let label = child.label, label.hasPrefix("_") else { continue }
            let name = path + label.dropFirst()
            let typeName = String(describing: type(of: child.value))
            let isWrapper = ["Option<", "Argument<", "Flag<", "OptionGroup<"]
                .contains { typeName.hasPrefix($0) }
            guard isWrapper else { continue }

            guard let parsed = Mirror(reflecting: child.value).children
                .first(where: { $0.label == "_parsedValue" })
            else {
                malformed.append("\(name): \(typeName) has no _parsedValue")
                continue
            }
            let parsedMirror = Mirror(reflecting: parsed.value)
            guard parsedMirror.displayStyle == .enum,
                  let caseChild = parsedMirror.children.first,
                  let caseLabel = caseChild.label
            else {
                malformed.append("\(name): Parsed<Value> shape unrecognized")
                continue
            }
            switch caseLabel {
            case "value":
                recognized += 1
                // An OptionGroup in value state carries a nested
                // ParsableArguments whose own wrappers may still be in
                // definition state — recurse.
                if let nested = caseChild.value as? any ParsableArguments {
                    walk(nested, path: name + ".")
                }
            case "definition":
                recognized += 1
                uninitialized.append(name)
            default:
                malformed.append("\(name): unknown Parsed case '\(caseLabel)'")
            }
        }
    }
}

private func assertFullyInitialized(
    _ instance: some ParsableArguments,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let audit = WrapperAudit(of: instance)
    #expect(
        audit.malformed.isEmpty,
        "ArgumentParser internals no longer match the pinned 1.5.0 shape — update WrapperAudit: \(audit.malformed)",
        sourceLocation: sourceLocation
    )
    #expect(
        audit.recognized > 0,
        "Audit found no ArgumentParser wrappers at all — the guard is blind (internals renamed?)",
        sourceLocation: sourceLocation
    )
    #expect(
        audit.uninitialized.isEmpty,
        "Properties still in wrapper-definition state — missed `sub.field = field` in makeIOSSubcommand? \(audit.uninitialized)",
        sourceLocation: sourceLocation
    )
}

@Suite("Forwarder initialization guard")
struct ForwarderInitializationGuardTests {
    private let iosUDID = "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0"

    // Meta-test: the audit must actually detect definition state, or
    // every green result below is vacuous. A hand-built command with
    // nothing assigned is the maximal violation.
    @Test("audit detects a hand-built, unassigned command")
    func auditDetectsDefinitionState() {
        let audit = WrapperAudit(of: IOSSimTapCommand())
        #expect(!audit.uninitialized.isEmpty)
        #expect(audit.malformed.isEmpty)
    }

    // Meta-test: a parsed command (never hand-copied) must audit clean —
    // proves the walk doesn't misclassify nil/default values as
    // uninitialized.
    @Test("audit passes a directly parsed command")
    func auditPassesParsedCommand() throws {
        assertFullyInitialized(try IOSSimTapCommand.parse(["@1", "--udid", iosUDID]))
    }

    @Test("tap forwarder copies every field")
    func tap() throws {
        assertFullyInitialized(try Tap.parse(["@1", "--udid", iosUDID]).makeIOSSubcommand())
    }

    @Test("long-press forwarder copies every field")
    func longPress() throws {
        assertFullyInitialized(try LongPress.parse(["@1", "--udid", iosUDID]).makeIOSSubcommand())
    }

    @Test("paste forwarder copies every field")
    func paste() throws {
        assertFullyInitialized(try Paste.parse(["hello", "--udid", iosUDID]).makeIOSSubcommand())
    }

    @Test("screenshot forwarder copies every field")
    func screenshot() throws {
        assertFullyInitialized(try Screenshot.parse(["--udid", iosUDID]).makeIOSSubcommand())
    }

    @Test("swipe forwarder copies every field")
    func swipe() throws {
        assertFullyInitialized(
            try Swipe.parse(["100,200", "300,400", "--udid", iosUDID]).makeIOSSubcommand()
        )
    }

    @Test("type forwarder copies every field")
    func type() throws {
        assertFullyInitialized(try Type.parse(["hello", "--udid", iosUDID]).makeIOSSubcommand())
    }

    @Test("record-video forwarder copies every field")
    func recordVideo() throws {
        assertFullyInitialized(try RecordVideo.parse(["--udid", iosUDID]).makeIOSSubcommand())
    }

    @Test("multi-touch forwarder copies every field")
    func multiTouch() throws {
        assertFullyInitialized(try MultiTouch.parse([
            "--x1", "195", "--y1", "422", "--x2", "195", "--y2", "522",
            "--x1-end", "195", "--y1-end", "222", "--x2-end", "195", "--y2-end", "622",
            "--udid", iosUDID,
        ]).makeIOSSubcommand())
    }

    @Test("button forwarder copies every field")
    func button() throws {
        assertFullyInitialized(try Button.parse(["home", "--udid", iosUDID]).makeIOSSubcommand())
    }

    @Test("touch forwarder copies every field")
    func touch() throws {
        assertFullyInitialized(try Touch.parse([
            "-x", "100", "-y", "200", "--down", "--up", "--udid", iosUDID,
        ]).makeIOSSubcommand())
    }

    @Test("describe-ui forwarder copies every field")
    func describeUI() throws {
        assertFullyInitialized(try DescribeUI.parse(["--udid", iosUDID]).makeIOSSubcommand())
    }

    @Test("keyboard-state forwarder copies every field")
    func keyboardState() throws {
        assertFullyInitialized(try KeyboardState.parse(["--udid", iosUDID]).makeIOSSubcommand())
    }

    @Test("gesture forwarder copies every field")
    func gesture() throws {
        assertFullyInitialized(try Gesture.parse(["scroll-up", "--udid", iosUDID]).makeIOSSubcommand())
    }
}
