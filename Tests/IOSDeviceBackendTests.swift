// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import Testing
@testable import iOSDeviceBackend

@Suite("Physical iOS device backend")
struct IOSDeviceBackendTests {
    @Test("an empty hierarchy fails with the development-signing requirement")
    func emptyHierarchyFailsLoudly() async {
        let client = AXAuditClient(transport: HierarchyTransport(result: .empty))

        do {
            _ = try await DeviceTreeFetcher(client: client).fetchTree()
            Issue.record("expected an empty hierarchy to fail")
        } catch {
            #expect(error.localizedDescription.contains("get-task-allow=true"))
            #expect(error.localizedDescription.contains("unlocked"))
        }
    }

    @Test("hierarchy transport failures are not flattened into an empty tree")
    func hierarchyFailurePropagates() async {
        let client = AXAuditClient(transport: HierarchyTransport(result: .failure))

        do {
            _ = try await DeviceTreeFetcher(client: client).fetchTree()
            Issue.record("expected the hierarchy read to fail")
        } catch {
            #expect(error is HierarchyTransport.Failure)
        }
    }

    @Test("a null root is retried until the element arrives")
    func nullRootIsRetriedUntilPresent() async throws {
        let root = AXAuditElement(token: Data(repeating: 0xA1, count: 20))
        let element = try await AXAuditClient(transport: TransientNullRootTransport(root: root)).rootElement()

        #expect(element == root)
    }

    @Test("persistent null roots exhaust the five-read limit")
    func persistentNullRootExhaustsReadLimit() async {
        // No pause and a budget these instant reads cannot reach, so the
        // five-read cap stops the loop, not the scheduling budget.
        let transport = ScriptedRootTransport(Array(repeating: .value(.null), count: 5))
        await expectNoRoot(reads: 5, from: transport) {
            try await AXAuditClient(transport: transport).rootElement(delay: .zero, budget: .seconds(30))
        }
    }

    @Test("a malformed non-null root is not retried")
    func malformedRootIsNotRetried() async {
        let malformed = AXAuditValue.object(tag: "AXAuditElement_v1", fields: [:])
        let transport = ScriptedRootTransport([.value(malformed)])
        await expectNoRoot(reads: 1, from: transport) {
            try await AXAuditClient(transport: transport).rootElement()
        }
    }

    @Test("a transport error reading the root is not retried")
    func rootTransportErrorIsNotRetried() async {
        let transport = ScriptedRootTransport([.failure])
        do {
            _ = try await AXAuditClient(transport: transport).rootElement()
            Issue.record("expected the transport error")
        } catch ScriptedRootTransport.Failure.transport {
        } catch {
            Issue.record("expected ScriptedRootTransport.Failure.transport, got \(error)")
        }
        #expect(await transport.reads == 1)
    }

    @Test("a slow null root exhausts the scheduling budget before five reads")
    func slowNullRootExhaustsSchedulingBudget() async {
        let transport = ScriptedRootTransport([
            .slowNull, .value(.null), .value(.null), .value(.null), .value(.null),
        ])
        await expectNoRoot(reads: 1, from: transport) {
            try await AXAuditClient(transport: transport).rootElement()
        }
    }

    @Test("a root that arrives on the fifth read is accepted")
    func rootOnFifthReadIsAccepted() async throws {
        let root = AXAuditElement(token: Data(repeating: 0xA5, count: 20))
        let transport = ScriptedRootTransport([
            .value(.null), .value(.null), .value(.null), .value(.null), .value(root.encoded),
        ])
        // No pause and a budget these instant reads cannot reach, so only the
        // read limit decides whether the fifth reply is used.
        let element = try await AXAuditClient(transport: transport).rootElement(delay: .zero, budget: .seconds(30))

        #expect(element == root)
        #expect(await transport.reads == 5)
    }

    @Test("cancellation during the root retry wait prevents another read")
    func cancellationDuringRootRetryWaitPreventsAnotherRead() async {
        let transport = ScriptedRootTransport(Array(repeating: .value(.null), count: 5))
        // A long pause, so the cancellation below always lands in it: with
        // the production 500 ms pause, a loaded test runner (the full suite,
        // CI) could finish the pause and read again first (#162).
        let task = Task {
            try await AXAuditClient(transport: transport).rootElement(delay: .seconds(60), budget: .seconds(120))
        }
        let started = ContinuousClock.now
        while await transport.reads < 1 {
            if ContinuousClock.now - started > .seconds(2) {
                Issue.record("root read did not start")
                task.cancel()
                _ = try? await task.value
                return
            }
            await Task.yield()
        }
        // The null is back; the client is in the pause before the next read.
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation to stop the retry")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        #expect(await transport.reads == 1)
    }

    private func expectNoRoot(
        reads expectedReads: Int,
        from transport: ScriptedRootTransport,
        _ body: () async throws -> AXAuditElement
    ) async {
        do {
            _ = try await body()
            Issue.record("expected AXAuditError.noRootElement")
        } catch AXAuditError.noRootElement {
        } catch {
            Issue.record("expected AXAuditError.noRootElement, got \(error)")
        }
        #expect(await transport.reads == expectedReads)
    }

    @Test("command help marks physical-device support as experimental and development-only")
    func commandHelpStatesSupportBoundary() async throws {
        let result = try await TestHelpers.runSimUseCommand("ios-device --help")

        #expect(result.output.localizedCaseInsensitiveContains("experimental"))
        #expect(result.output.contains("development-signed"))
        #expect(result.output.contains("get-task-allow=true"))
    }

    @Test("only positive DTX conversation indices are replies")
    func dtxReplyClassificationUsesConversationIndex() {
        var event = DTXFraming.Header()
        event.identifier = 42
        event.conversationIndex = 0

        var reply = event
        reply.conversationIndex = 1

        #expect(!event.isReply)
        #expect(reply.isReply)
    }

    @Test("device discovery settles only after the last attachment is quiet")
    func deviceDiscoveryUsesAQuiescenceWindow() {
        let start = Date(timeIntervalSince1970: 1_000)
        var tracker = AttachmentQuiescence<String>(quietInterval: 0.25)

        let firstArrival = tracker.observe(["first"], at: start)
        let beforeFirstSettles = tracker.observe(["first"], at: start.addingTimeInterval(0.24))
        let secondArrival = tracker.observe(["first", "second"], at: start.addingTimeInterval(0.24))
        let beforeSecondSettles = tracker.observe(["first", "second"], at: start.addingTimeInterval(0.48))
        let settled = tracker.observe(["first", "second"], at: start.addingTimeInterval(0.50))

        #expect(!firstArrival)
        #expect(!beforeFirstSettles)
        #expect(!secondArrival)
        #expect(!beforeSecondSettles)
        #expect(settled)
    }

    @Test("discovery bails once the empty-grace window elapses with no device")
    func discoveryBailsWhenEmpty() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var discovery = AttachmentDiscovery<String>(quietInterval: 0.25, emptyGrace: 1.0)

        #expect(discovery.step([], at: t0) == .keepWaiting)
        #expect(discovery.step([], at: t0.addingTimeInterval(0.9)) == .keepWaiting)
        #expect(discovery.step([], at: t0.addingTimeInterval(1.0)) == .bailEmpty)
    }

    @Test("a device seen before the grace prevents the empty bail and settles")
    func discoverySettlesWhenDeviceAppears() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var discovery = AttachmentDiscovery<String>(quietInterval: 0.25, emptyGrace: 1.0)

        #expect(discovery.step([], at: t0) == .keepWaiting)
        #expect(discovery.step(["a"], at: t0.addingTimeInterval(0.1)) == .keepWaiting)
        #expect(discovery.step(["a"], at: t0.addingTimeInterval(0.35)) == .settled)
    }

    @Test("a device appearing at the grace boundary latches sawAny and never bails")
    func discoveryLateDeviceStillSettles() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var discovery = AttachmentDiscovery<String>(quietInterval: 0.25, emptyGrace: 1.0)

        #expect(discovery.step([], at: t0) == .keepWaiting)
        // Device shows up exactly at the grace boundary: sawAny latches, so we
        // must not bail; the quiescence window then settles it.
        #expect(discovery.step(["a"], at: t0.addingTimeInterval(1.0)) == .keepWaiting)
        #expect(discovery.step(["a"], at: t0.addingTimeInterval(1.3)) == .settled)
    }

    @Test("exact label matching prefers the button over duplicate static text")
    func exactLabelPrefersButton() throws {
        let text = element(1, summary: "Friends Static Text", role: "Static Text")
        let button = element(2, summary: "Friends Button", role: "Button")

        let resolved = try DeviceTapTargetResolver.resolve(
            [text, button],
            label: "Friends",
            labelContains: nil,
            elementType: nil
        )

        #expect(resolved.element == button.element)
    }

    @Test("identifier selector matches the stable id, not the dynamic label")
    func identifierSelectorMatches() throws {
        let back = element(1, summary: "sim-use Playground Button", role: "Button", identifier: "BackButton")
        let other = element(2, summary: "Settings Button", role: "Button", identifier: "settingsButton")

        let resolved = try DeviceTapTargetResolver.resolve(
            [back, other],
            identifier: "BackButton"
        )

        #expect(resolved.element == back.element)
    }

    @Test("a missing identifier fails loudly")
    func missingIdentifierFails() {
        let button = element(1, summary: "Settings Button", role: "Button", identifier: "settingsButton")
        #expect(throws: IOSDeviceCommandError.self) {
            _ = try DeviceTapTargetResolver.resolve([button], identifier: "BackButton")
        }
    }

    @Test("a duplicated identifier is ambiguous and never silently prefers a Button")
    func duplicateIdentifierIsAmbiguous() throws {
        // Button-preference is a label-only tie-break; an id is meant to be
        // unique, so a duplicate must error rather than resolve to the button.
        let text = element(1, summary: "Save", role: "Static Text", identifier: "save")
        let button = element(2, summary: "Save", role: "Button", identifier: "save")

        #expect(throws: IOSDeviceCommandError.self) {
            _ = try DeviceTapTargetResolver.resolve([text, button], identifier: "save")
        }

        // --element-type narrowing to a single match still resolves.
        let narrowed = try DeviceTapTargetResolver.resolve([text, button], identifier: "save", elementType: "Button")
        #expect(narrowed.element == button.element)
    }

    @Test("a whitespace-padded daemon identifier still matches the clean selector")
    func identifierMatchingTrimsBothSides() throws {
        // The daemon can report a padded id; ui renders it trimmed, so a user
        // (or the docs) passes the clean form. Both sides must trim to match.
        let padded = element(1, summary: "sim-use Playground Button", role: "Button", identifier: " BackButton ")

        let byClean = try DeviceTapTargetResolver.resolve([padded], identifier: "BackButton")
        #expect(byClean.element == padded.element)

        let byPadded = try DeviceTapTargetResolver.resolve([padded], identifier: "  BackButton  ")
        #expect(byPadded.element == padded.element)
    }

    @Test("the outline renders identifiers trimmed so the shown #id is copy-safe")
    func outlineTrimsIdentifierForDisplay() {
        let rendered = DeviceOutline(elements: [
            element(1, summary: "Back Button", role: "Button", identifier: " BackButton "),
        ]).rendered()

        #expect(rendered.contains("#BackButton"))
        #expect(!rendered.contains("# BackButton "))
    }

    @Test("identifier matching is exact and case-sensitive, unlike labels")
    func identifierMatchingIsExact() throws {
        let upper = element(1, summary: "Back", role: "Button", identifier: "BackButton")
        let lower = element(2, summary: "back", role: "Button", identifier: "backButton")

        // Two differently-cased ids are distinct identities — exact match picks one.
        let resolved = try DeviceTapTargetResolver.resolve([upper, lower], identifier: "BackButton")
        #expect(resolved.element == upper.element)

        // A case-mismatched query is a literal miss, not a fuzzy merge.
        #expect(throws: IOSDeviceCommandError.self) {
            _ = try DeviceTapTargetResolver.resolve([upper, lower], identifier: "BACKBUTTON")
        }
    }

    @Test("physical-device tap accepts #id but rejects an @N alias")
    func tapAcceptsIdentifierRejectsAlias() async throws {
        let atAlias = try await TestHelpers.runSimUseCommandAllowFailure("ios-device tap @1 --device not-a-device")
        #expect(atAlias.exitCode != 0)
        #expect(atAlias.output.contains("@N"))

        let help = try await TestHelpers.runSimUseCommand("ios-device tap --help")
        #expect(help.output.contains("--id <id>"))
        #expect(help.output.contains("#<id>"))
    }

    @Test("label matching is case-sensitive, using the shared simulator/Android policy")
    func labelMatchingIsCaseSensitive() throws {
        let button = element(1, summary: "Friends Button", role: "Button")

        let exact = try DeviceTapTargetResolver.resolve([button], label: "Friends")
        #expect(exact.element == button.element)

        // Wrong case is a miss — the shared SelectorTextMatcher is case-sensitive,
        // so physical-device label matching no longer drifts from the simulator.
        #expect(throws: IOSDeviceCommandError.self) {
            _ = try DeviceTapTargetResolver.resolve([button], label: "friends")
        }
    }

    @Test("element type narrows a contains selector")
    func elementTypeNarrowsContainsSelector() throws {
        let button = element(1, summary: "Friends Button", role: "Button")
        let header = element(2, summary: "Friends Header", role: "Header")

        let resolved = try DeviceTapTargetResolver.resolve(
            [button, header],
            label: nil,
            labelContains: "Friend",
            elementType: "Header"
        )

        #expect(resolved.element == header.element)
    }

    @Test("ambiguous and missing tap targets are runtime errors, not usage errors")
    func tapResolutionFailsLoudly() {
        let first = element(1, summary: "Save Button", role: "Button")
        let second = element(2, summary: "Save Button", role: "Button")

        for (elements, needle) in [([first, second], "Save"), ([first], "Missing")] {
            do {
                _ = try DeviceTapTargetResolver.resolve(
                    elements,
                    label: needle,
                    labelContains: nil,
                    elementType: nil
                )
                Issue.record("expected tap target resolution to fail")
            } catch {
                #expect(error is IOSDeviceCommandError)
                #expect(!(error is ValidationError))
            }
        }
    }

    @Test("physical-device outline does not advertise unusable cross-session aliases")
    func outlineOmitsAliases() {
        let rendered = DeviceOutline(elements: [
            element(1, summary: "Friends Button", role: "Button"),
        ]).rendered()

        #expect(!rendered.contains("@1"))
        #expect(rendered.contains("Button  \"Friends\""))
    }

    @Test("physical-device outline renders a stable accessibility identifier")
    func outlineRendersIdentifier() {
        let rendered = DeviceOutline(elements: [
            element(1, summary: "sim-use Playground Button", role: "Button", identifier: "BackButton"),
            element(2, summary: "Friends Button", role: "Button"),
        ]).rendered()

        // The dynamic back-button label is joined to its stable id so an agent
        // can key off the id instead of the previous screen's title.
        #expect(rendered.contains("Button  \"sim-use Playground\"  #BackButton"))
        // Elements without an identifier render no trailing `#`.
        #expect(rendered.contains("Button  \"Friends\"\n") || rendered.hasSuffix("Button  \"Friends\""))
    }

    @Test("tap help uses the shared label selector vocabulary")
    func tapHelpUsesStandardSelectors() async throws {
        let result = try await TestHelpers.runSimUseCommand("ios-device tap --help")

        #expect(result.output.contains("--label <label>"))
        #expect(result.output.contains("--label-contains <label-contains>"))
        #expect(result.output.contains("--element-type <element-type>"))
        #expect(!result.output.contains("--text"))
    }

    @Test("invalid hierarchy tuning fails before device discovery")
    func invalidHierarchyTuningIsAUsageError() async throws {
        for option in ["--concurrency 0", "--connections 0"] {
            let result = try await TestHelpers.runSimUseCommandAllowFailure(
                "ios-device ui \(option) --device not-a-device"
            )

            #expect(result.exitCode != 0)
            #expect(result.output.contains("greater than zero"))
            #expect(!result.output.contains("no physical iOS device"))
        }
    }

    @Test("screenshot pins the devicectl argument vector")
    func screenshotArgumentsAreStable() {
        let args = Devicectl.screenshotArguments(
            deviceIdentifier: "00008130-00066D2A10EB8D3A",
            destination: URL(fileURLWithPath: "/tmp/shot.png")
        )
        #expect(args == [
            "devicectl", "device", "capture", "screenshot",
            "--device", "00008130-00066D2A10EB8D3A",
            "--destination", "/tmp/shot.png",
            "--timeout", "30",
            "--quiet",
        ])
    }

    @Test("devicectl failures surface the exit code and stderr")
    func devicectlFailureSurfacesStderr() {
        do {
            try Devicectl.run(arguments: ["-c", "echo boom >&2; exit 3"], executablePath: "/bin/sh")
            Issue.record("expected a non-zero exit to throw")
        } catch {
            #expect(error.localizedDescription.contains("exited 3"))
            #expect(error.localizedDescription.contains("boom"))
        }
    }

    @Test("devicectl success is silent")
    func devicectlSuccessRuns() throws {
        try Devicectl.run(arguments: ["-c", "echo ok"], executablePath: "/bin/sh")
    }

    @Test("device screenshot default filename mirrors the simulator convention")
    func screenshotDefaultFilenameConvention() {
        let name = IOSDeviceCommand.Screenshot.defaultFilename(
            deviceName: "iPhone One",
            at: Date(timeIntervalSince1970: 0)
        )
        #expect(name.hasPrefix("Device Screenshot - iPhone One - "))
        #expect(name.hasSuffix(".png"))
    }

    @Test("a device name containing path separators stays a single filename component")
    func deviceNameWithSlashesStaysSingleComponent() {
        let name = IOSDeviceCommand.Screenshot.defaultFilename(
            deviceName: "My iPhone/Work",
            at: Date(timeIntervalSince1970: 0)
        )
        #expect(!name.contains("/"))
        #expect(name.hasPrefix("Device Screenshot - My iPhone-Work - "))
    }

    @Test("a traversal-shaped device name cannot escape the current directory")
    func traversalDeviceNameResolvesIntoCwd() throws {
        let url = try IOSDeviceCommand.Screenshot.resolveOutputURL(output: nil, deviceName: "../../evil")
        #expect(url.deletingLastPathComponent().path == FileManager.default.currentDirectoryPath)
        #expect(!url.lastPathComponent.contains("/"))
    }

    @Test("a NAME_MAX-length target name still captures — the temporary name is independent of it")
    func maxLengthTargetNameCaptures() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = String(repeating: "a", count: 251) + ".png"
        #expect(name.utf8.count == 255)
        let target = dir.appendingPathComponent(name)

        try IOSDeviceCommand.Screenshot.captureAtomically(to: target) { temporary in
            try Data("fresh".utf8).write(to: temporary)
        }
        #expect(try Data(contentsOf: target) == Data("fresh".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [name])
    }

    @Test("a rejected non-PNG output path leaves the existing file intact")
    func rejectedOutputPreservesExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = dir.appendingPathComponent("important.jpg")
        let precious = Data("precious".utf8)
        try precious.write(to: existing)

        #expect(throws: (any Error).self) {
            _ = try IOSDeviceCommand.Screenshot.resolveOutputURL(output: existing.path, deviceName: "iPhone One")
        }
        #expect(try Data(contentsOf: existing) == precious)
    }

    @Test("an accepted PNG output path defers deletion — the existing file survives resolution")
    func acceptedOutputLeavesExistingFileUntilCapture() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = dir.appendingPathComponent("shot.png")
        let stale = Data("stale".utf8)
        try stale.write(to: existing)

        let url = try IOSDeviceCommand.Screenshot.resolveOutputURL(output: existing.path, deviceName: "iPhone One")
        #expect(url == existing)
        #expect(try Data(contentsOf: existing) == stale)
    }

    @Test("a failed capture leaves the existing screenshot intact and no temporary behind")
    func failedCapturePreservesExistingFile() throws {
        struct CaptureFailed: Error {}
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("important.png")
        let precious = Data("precious".utf8)
        try precious.write(to: target)

        #expect(throws: CaptureFailed.self) {
            try IOSDeviceCommand.Screenshot.captureAtomically(to: target) { temporary in
                try Data("partial".utf8).write(to: temporary)
                throw CaptureFailed()
            }
        }
        #expect(try Data(contentsOf: target) == precious)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["important.png"])
    }

    @Test("a successful capture atomically replaces the existing screenshot")
    func successfulCaptureReplacesExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("shot.png")
        try Data("stale".utf8).write(to: target)

        try IOSDeviceCommand.Screenshot.captureAtomically(to: target) { temporary in
            try Data("fresh".utf8).write(to: temporary)
        }
        #expect(try Data(contentsOf: target) == Data("fresh".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["shot.png"])
    }

    @Test("a successful capture creates the target when none exists")
    func successfulCaptureCreatesFreshFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("shot.png")

        try IOSDeviceCommand.Screenshot.captureAtomically(to: target) { temporary in
            try Data("fresh".utf8).write(to: temporary)
        }
        #expect(try Data(contentsOf: target) == Data("fresh".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["shot.png"])
    }

    @Test("physical device summaries map to unified ios/physical rows")
    func deviceSummaryMapsToUnifiedRow() {
        let summary = DeviceSession.DeviceSummary(
            udid: "00008130-00066D2A10EB8D3A",
            name: "iPhone One",
            osVersion: "iOS 26.6",
            state: "Booted"
        )
        let device = summary.unifiedDevice
        #expect(device.platform == .ios)
        #expect(device.kind == .physical)
        #expect(device.udid == "00008130-00066D2A10EB8D3A")
        #expect(device.name == "iPhone One")
        #expect(device.runtime == "iOS 26.6")
        #expect(device.isUsable)
    }

    @Test("device selection errors tell the user how to recover")
    func deviceSelectionErrorsAreActionable() {
        let none = DeviceSessionError.noDevices
        let multiple = DeviceSessionError.selectionRequired(available: ["device-a", "device-b"])

        #expect(none.localizedDescription.contains("no physical iOS devices"))
        #expect(none.hint?.contains("USB") == true)
        // The candidate list stays in the description; the recovery advice
        // moved to the hint channel so the --json envelope carries it
        // structurally.
        #expect(multiple.localizedDescription.contains("device-a"))
        #expect(multiple.localizedDescription.contains("device-b"))
        #expect(multiple.hint?.contains("--device") == true)
    }

    @Test("tap resolution errors carry their recovery advice as hints")
    func tapResolutionErrorsCarryHints() {
        let missing = IOSDeviceCommandError.noMatchingElement(selector: "--label 'X'", available: ["'A' [Button]"])
        let ambiguous = IOSDeviceCommandError.multipleMatches(selector: "--label 'Save'", matches: ["'Save' [Button]", "'Save' [Static Text]"])

        #expect(missing.localizedDescription.contains("'A' [Button]"))
        #expect(missing.hint?.contains("ios-device ui") == true)
        #expect(ambiguous.localizedDescription.contains("'Save' [Static Text]"))
        #expect(ambiguous.hint?.contains("--element-type") == true)
        #expect(IOSDeviceCommandError.missingSelector.hint == nil)
    }

    // MARK: - SimUseExecutableCommand conformance (#108)

    @Test("every ios-device verb advertises --json in its help")
    func verbsAdvertiseJSONFlag() async throws {
        for verb in ["devices", "ui", "screenshot", "tap"] {
            let result = try await TestHelpers.runSimUseCommand("ios-device \(verb) --help")
            #expect(result.output.contains("--json"), "\(verb) --help should document --json")
        }
    }

    @Test("ios-device verbs stay in-process — no daemon UDID is ever offered")
    func verbsDoNotOfferADaemonUDID() throws {
        // PR B is structural alignment only: every ios-device call still
        // opens its own DTX session. Daemon session persistence is #120.
        try #expect(IOSDeviceCommand.Devices.parse([]).simulatorUDIDForDaemon == nil)
        try #expect(IOSDeviceCommand.UI.parse(["--device", "X"]).simulatorUDIDForDaemon == nil)
        try #expect(IOSDeviceCommand.Screenshot.parse(["--device", "X"]).simulatorUDIDForDaemon == nil)
        try #expect(IOSDeviceCommand.Tap.parse(["--id", "x", "--device", "X"]).simulatorUDIDForDaemon == nil)
    }

    @Test("devices format keeps the legacy row shape and no-device line")
    func devicesFormatMatchesLegacyShape() throws {
        let command = try IOSDeviceCommand.Devices.parse([])

        #expect(command.format(.init(devices: [])).stdout == "No physical iOS devices connected.\n")

        let summary = DeviceSession.DeviceSummary(
            udid: "00008130-00066D2A10EB8D3A",
            name: "iPhone One",
            osVersion: "iOS 26.6",
            state: "Booted"
        )
        let listed = command.format(.init(devices: [summary.unifiedDevice]))
        #expect(listed.stdout == "00008130-00066D2A10EB8D3A  iPhone One  iOS 26.6  Booted\n")
    }

    @Test("devices --json rows reuse the unified Device schema")
    func devicesResultEncodesUnifiedRows() throws {
        let summary = DeviceSession.DeviceSummary(
            udid: "00008130-00066D2A10EB8D3A",
            name: "iPhone One",
            osVersion: "iOS 26.6",
            state: "Booted"
        )
        let data = try JSONEncoder().encode(IOSDeviceCommand.Devices.ExecutionResult(devices: [summary.unifiedDevice]))
        let json = String(decoding: data, as: UTF8.self)

        // Same keys as top-level `sim-use devices --json`: canonical
        // `deviceId`, orthogonal `kind`, `runtime` carrying the OS.
        #expect(json.contains("\"deviceId\":\"00008130-00066D2A10EB8D3A\""))
        #expect(json.contains("\"kind\":\"physical\""))
        #expect(json.contains("\"runtime\":\"iOS 26.6\""))
        #expect(!json.contains("\"osVersion\""))
    }

    @Test("ui format reproduces the outline plus summary line byte-for-byte")
    func uiFormatMatchesLegacyShape() throws {
        let outline = DeviceOutline(elements: [
            element(1, summary: "Friends Button", role: "Button"),
        ])
        let result = IOSDeviceCommand.UI.ExecutionResult(
            outline: outline.rendered(),
            rows: outline.rows,
            elements: outline.rows.count,
            nodes: 3,
            elapsedMs: 1234
        )
        let output = try IOSDeviceCommand.UI.parse([]).format(result)

        #expect(output.stdout == "Button  \"Friends\"\n\n1 elements (3 nodes) in 1234 ms\n")
        #expect(output.stderr.isEmpty)
    }

    @Test("ui --json rows omit the identifier key when the element has none")
    func uiResultRowsOmitNilIdentifier() throws {
        let rows = DeviceOutline(elements: [
            element(1, summary: "Back Button", role: "Button", identifier: "BackButton"),
            element(2, summary: "Friends Button", role: "Button"),
        ]).rows
        let data = try JSONEncoder().encode(rows)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains("\"identifier\":\"BackButton\""))
        #expect(!json.contains("\"identifier\":null"))

        let decoded = try JSONDecoder().decode([DeviceOutline.Row].self, from: data)
        #expect(decoded == rows)
    }

    @Test("tap format reports the matched element in the resolver vocabulary")
    func tapFormatMatchesLegacyShape() throws {
        let command = try IOSDeviceCommand.Tap.parse(["--id", "settingsButton"])

        let withId = command.format(.init(action: "Activate", role: "Button", label: "Settings", identifier: "settingsButton"))
        #expect(withId.stdout == "Sent Activate to 'Settings' [Button] #settingsButton\n")

        let withoutId = command.format(.init(action: "Activate", role: "Button", label: "Friends", identifier: nil))
        #expect(withoutId.stdout == "Sent Activate to 'Friends' [Button]\n")
    }

    @Test("tap --json omits the identifier key when the element has none")
    func tapResultOmitsNilIdentifier() throws {
        let data = try JSONEncoder().encode(
            IOSDeviceCommand.Tap.ExecutionResult(action: "Activate", role: "Button", label: "Friends", identifier: nil)
        )
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains("\"action\":\"Activate\""))
        #expect(!json.contains("\"identifier\""))
    }

    @Test("screenshot format prints the path on stdout and the confirmation on stderr")
    func screenshotFormatMatchesLegacyShape() throws {
        let output = try IOSDeviceCommand.Screenshot.parse([]).format(.init(path: "/tmp/shot.png"))

        #expect(output.stdout == "/tmp/shot.png\n")
        #expect(output.stderr == "Screenshot saved to /tmp/shot.png\n")
    }

    private func element(
        _ tokenByte: UInt8,
        summary: String,
        role: String,
        identifier: String? = nil,
        isIgnored: Bool = false
    ) -> DeviceElement {
        DeviceElement(
            element: AXAuditElement(token: Data(repeating: tokenByte, count: 20)),
            summary: summary,
            role: role,
            identifier: identifier,
            depth: 0,
            parent: nil,
            isIgnored: isIgnored
        )
    }
}

private actor HierarchyTransport: DTXInvoking {
    enum Result {
        case empty
        case failure
    }

    enum Failure: Error {
        case hierarchyReadFailed
    }

    private let result: Result
    private let root = AXAuditElement(token: Data(repeating: 0x01, count: 20))

    init(result: Result) {
        self.result = result
    }

    func invoke(
        _ selector: String,
        arguments: [AXAuditValue],
        expectsReply: Bool
    ) async throws -> AXAuditValue {
        switch selector {
        case "deviceFetchSpecialElement:":
            return root.encoded
        case "deviceElement:valueForAttribute:":
            switch result {
            case .empty:
                return .null
            case .failure:
                throw Failure.hierarchyReadFailed
            }
        default:
            return .null
        }
    }
}

/// First `deviceFetchSpecialElement:` is null; the next one is the element.
private actor TransientNullRootTransport: DTXInvoking {
    private let root: AXAuditElement
    private var servedNull = false

    init(root: AXAuditElement) {
        self.root = root
    }

    func invoke(
        _ selector: String,
        arguments: [AXAuditValue],
        expectsReply: Bool
    ) async throws -> AXAuditValue {
        guard selector == "deviceFetchSpecialElement:" else { return .null }
        if servedNull { return root.encoded }
        servedNull = true
        return .null
    }
}

/// Scripted `deviceFetchSpecialElement:` replies for the root-retry boundaries.
/// A read past the script fails instead of hanging a retry loop that no longer stops.
private actor ScriptedRootTransport: DTXInvoking {
    enum Step: Sendable {
        case value(AXAuditValue)
        case failure
        /// Holds the read open until the production two-second scheduling budget has passed.
        case slowNull
    }

    enum Failure: Error {
        case transport
        case unexpectedRead
    }

    private let steps: [Step]
    private(set) var reads = 0

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func invoke(
        _ selector: String,
        arguments: [AXAuditValue],
        expectsReply: Bool
    ) async throws -> AXAuditValue {
        guard selector == "deviceFetchSpecialElement:" else { return .null }
        let index = reads
        reads += 1
        guard index < steps.count else { throw Failure.unexpectedRead }
        switch steps[index] {
        case let .value(value):
            return value
        case .failure:
            throw Failure.transport
        case .slowNull:
            try await Self.waitPastSchedulingBudget()
            return .null
        }
    }

    /// Production measures two seconds from before this read. Waiting this long
    /// on the same clock lands after that deadline even if a slice wakes early.
    private static func waitPastSchedulingBudget() async throws {
        let clock = ContinuousClock()
        let until = clock.now.advanced(by: .milliseconds(2_100))
        while clock.now < until {
            let remaining = until - clock.now
            if remaining <= .zero { return }
            try await clock.sleep(for: min(.milliseconds(50), remaining), tolerance: .zero)
        }
    }
}
