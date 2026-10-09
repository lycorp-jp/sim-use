// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

// Unit coverage for the Xcode 27 resizable app session (Resize Mode)
// stop-gap — issue #143. No simulator needed: the devicectl document
// shapes below were captured live on Xcode 27.0 (27A266a) / iOS 27.0
// (24A434) and are pinned here so a CoreDevice change shows up as a
// failing test rather than a silently wrong classification. The live
// counterpart is the SIM_USE_E2E-gated `ResizeModeTests`.

// MARK: - Fixtures (verbatim devicectl `--json-output -` documents, trimmed)

/// `devicectl device info appResize` with a session active (exit 0).
private let activeDocument = """
{
  "info" : { "commandType" : "devicectl.device.info.appResize", "jsonVersion" : 5, "outcome" : "success", "version" : "651.13.5" },
  "result" : {
    "cornerRadius" : 0,
    "deviceIdentifier" : "4F480C10-679A-47F3-AE36-99D0EC643774",
    "displayName" : "Resizable",
    "displayUniqueId" : "0933D2CA-38DF-4B17-9934-7CDC624B355C",
    "maximumPossibleSize" : [ 1280, 1280 ],
    "minimumPossibleSize" : [ 0, 0 ],
    "preferredSize" : [ 560, 874 ]
  }
}
"""

/// No session (exit 1). The same document comes back from an Xcode 26.6
/// devicectl, which already knows the subcommand.
private let inactiveDocument = """
{
  "error" : {
    "code" : 24004,
    "domain" : "com.apple.dt.CoreDeviceError",
    "userInfo" : {
      "NSLocalizedDescription" : { "string" : "Failed to query resizable app session state." },
      "NSLocalizedFailureReason" : { "string" : "The specified display is not currently hosting a resizable app session." }
    }
  },
  "errorSignature" : "(com.apple.dt.CoreDeviceError 24004)",
  "info" : { "commandType" : "devicectl.device.info.appResize", "jsonVersion" : 5, "outcome" : "failed", "version" : "651.13.5" }
}
"""

/// Simulator unknown to CoreDevice (exit 1).
private let deviceNotFoundDocument = """
{
  "error" : {
    "code" : 1000,
    "domain" : "com.apple.dt.CoreDeviceError",
    "userInfo" : {
      "DeviceName" : { "string" : "00000000-0000-0000-0000-000000000000" },
      "NSLocalizedDescription" : { "string" : "The specified device was not found. (Name: 00000000-0000-0000-0000-000000000000)" }
    }
  },
  "errorSignature" : "(com.apple.dt.CoreDeviceError 1000)",
  "info" : { "outcome" : "failed" }
}
"""

private let sampleSession = ResizableAppSession(
    displayUniqueID: "0933D2CA-38DF-4B17-9934-7CDC624B355C",
    displayName: "Resizable",
    preferredWidth: 560,
    preferredHeight: 874
)

private func classify(_ document: String, status: Int32, stderr: String = "") -> ResizableAppSessionState {
    ResizableAppSessionProbe.classify(terminationStatus: status, stdout: Data(document.utf8), stderr: Data(stderr.utf8))
}

// MARK: - Probe classification

@Suite("ResizableAppSessionProbe — devicectl document classification")
struct ResizableAppSessionProbeTests {
    @Test("an active session document yields the display and requested size")
    func activeDocumentIsActive() {
        let state = classify(activeDocument, status: 0)
        #expect(state == .active(sampleSession))
        #expect(state.session?.preferredSizeDescription == "560x874")
    }

    @Test("CoreDeviceError 24004 means no session")
    func noSessionErrorIsInactive() {
        #expect(classify(inactiveDocument, status: 1) == .inactive)
    }

    @Test("an unknown device is unavailable, not inactive, and names the code")
    func deviceNotFoundIsUnavailable() {
        guard case .unavailable(let reason) = classify(deviceNotFoundDocument, status: 1) else {
            Issue.record("expected .unavailable")
            return
        }
        #expect(reason.contains("1000"))
        #expect(reason.contains("not found"))
    }

    @Test("a devicectl without the subcommand is unavailable and says so")
    func missingSubcommandIsUnavailable() {
        let state = classify("", status: 64, stderr: "Error: Unrecognized subcommand 'appResize'\nUsage: devicectl device info <subcommand>")
        guard case .unavailable(let reason) = state else {
            Issue.record("expected .unavailable")
            return
        }
        #expect(reason.contains("subcommand"))
    }

    @Test("garbage output is unavailable and carries the exit status")
    func garbageIsUnavailable() {
        guard case .unavailable(let reason) = classify("not json", status: 3, stderr: "boom") else {
            Issue.record("expected .unavailable")
            return
        }
        #expect(reason.contains("exited 3"))
        #expect(reason.contains("boom"))
    }

    @Test("the document decides, not the exit status")
    func documentWinsOverStatus() {
        // A zero exit with an error document is still no session; a
        // non-zero exit with a result document is still active.
        #expect(classify(inactiveDocument, status: 0) == .inactive)
        #expect(classify(activeDocument, status: 1) == .active(sampleSession))
    }

    @Test("a result without a display id or size is not trusted")
    func incompleteResultIsUnavailable() {
        let partial = #"{"result": {"displayName": "Resizable"}, "info": {"outcome": "success"}}"#
        guard case .unavailable = classify(partial, status: 0) else {
            Issue.record("expected .unavailable")
            return
        }
    }

    @Test("devicectl argument vector is pinned")
    func argumentsArePinned() {
        #expect(ResizableAppSessionProbe.arguments(udid: "ABC") == [
            "devicectl", "device", "info", "appResize",
            "--device", "ABC",
            "--json-output", "-",
            "--timeout", "5",
            "--quiet",
        ])
    }

    @Test("run() drains both pipes and classifies the real process outcome")
    func runClassifiesLiveProcess() {
        // Drive the drain against /bin/sh: an active document on stdout
        // and noise on stderr, non-zero exit — still active.
        let script = "printf '%s' '\(activeDocument.replacingOccurrences(of: "'", with: "'\\''").replacingOccurrences(of: "\n", with: " "))'; echo noise >&2; exit 1"
        let state = ResizableAppSessionProbe.run(udid: "ignored", executablePath: "/bin/sh", arguments: ["-c", script])
        #expect(state == .active(sampleSession))
    }

    @Test("run() reports a spawn failure as unavailable instead of throwing")
    func runSpawnFailureIsUnavailable() {
        guard case .unavailable(let reason) = ResizableAppSessionProbe.run(udid: "x", executablePath: "/nonexistent/devicectl") else {
            Issue.record("expected .unavailable")
            return
        }
        #expect(reason.contains("spawn"))
    }
}

// MARK: - Monitor cache

@Suite("ResizableAppSessionMonitor — per-UDID TTL cache")
struct ResizableAppSessionMonitorTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var now = Date(timeIntervalSince1970: 1_000_000)
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return now }
        func advance(_ seconds: TimeInterval) { lock.lock(); now = now.addingTimeInterval(seconds); lock.unlock() }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        var states: [ResizableAppSessionState] = []
        func record(_ udid: String) -> ResizableAppSessionState {
            lock.lock(); defer { lock.unlock() }
            calls.append(udid)
            return states.isEmpty ? .inactive : states.removeFirst()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
        var udids: [String] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    private func makeMonitor(
        clock: Clock,
        counter: Counter,
        ttl: TimeInterval = 5,
        environment: [String: String] = [:]
    ) -> ResizableAppSessionMonitor {
        ResizableAppSessionMonitor(
            ttl: ttl,
            clock: { clock.read() },
            probe: { counter.record($0) },
            environment: environment
        )
    }

    @Test("repeated queries inside the TTL probe once; the TTL expiring re-probes")
    func cachesWithinTTL() async {
        let clock = Clock()
        let counter = Counter()
        counter.states = [.active(sampleSession), .inactive]
        let monitor = makeMonitor(clock: clock, counter: counter)

        #expect(await monitor.state(for: "A") == .active(sampleSession))
        #expect(await monitor.state(for: "A") == .active(sampleSession))
        #expect(counter.count == 1)

        clock.advance(5.1)
        #expect(await monitor.state(for: "A") == .inactive)
        #expect(counter.count == 2)
    }

    @Test("UDIDs are cached independently")
    func cachesPerUDID() async {
        let clock = Clock()
        let counter = Counter()
        counter.states = [.active(sampleSession), .inactive]
        let monitor = makeMonitor(clock: clock, counter: counter)

        #expect(await monitor.state(for: "A") == .active(sampleSession))
        #expect(await monitor.state(for: "B") == .inactive)
        #expect(counter.udids == ["A", "B"])
    }

    private let resizedScene = ResizableAppSessionMonitor.SceneEvidence(width: 560, height: 874)
    private let otherScene = ResizableAppSessionMonitor.SceneEvidence(width: 375, height: 667)

    @Test("new scene evidence bypasses a cached inactive answer; a cached active one is never bypassed")
    func evidenceBypassesInactive() async {
        let clock = Clock()
        let counter = Counter()
        counter.states = [.inactive, .active(sampleSession), .inactive]
        let monitor = makeMonitor(clock: clock, counter: counter)

        #expect(await monitor.state(for: "A") == .inactive)
        // In-band evidence of a session: re-probe despite the fresh cache.
        #expect(await monitor.state(for: "A", evidence: resizedScene) == .active(sampleSession))
        #expect(counter.count == 2)
        // Now active and cached: evidence — even different evidence — does
        // not force another probe.
        #expect(await monitor.state(for: "A", evidence: otherScene) == .active(sampleSession))
        #expect(counter.count == 2)
    }

    @Test("the same evidence seen again rides the cache (R150-03: a downscaled display is not a resize per fetch)")
    func repeatedEvidenceDoesNotReprobe() async {
        let clock = Clock()
        let counter = Counter()
        let monitor = makeMonitor(clock: clock, counter: counter)

        #expect(await monitor.state(for: "A", evidence: resizedScene) == .inactive)
        #expect(await monitor.state(for: "A", evidence: resizedScene) == .inactive)
        #expect(await monitor.state(for: "A", evidence: resizedScene) == .inactive)
        #expect(counter.count == 1)
        // Evidence that *changes* inside the TTL is a different scene: re-probe.
        counter.states = [.active(sampleSession)]
        #expect(await monitor.state(for: "A", evidence: otherScene) == .active(sampleSession))
        #expect(counter.count == 2)
    }

    @Test("evidence after a probe without evidence re-probes; no evidence after an evidence probe does not")
    func evidenceVersusNoEvidence() async {
        let clock = Clock()
        let counter = Counter()
        let monitor = makeMonitor(clock: clock, counter: counter)

        _ = await monitor.state(for: "A")
        _ = await monitor.state(for: "A", evidence: resizedScene)
        #expect(counter.count == 2)
        _ = await monitor.state(for: "A")
        #expect(counter.count == 2)
    }

    @Test("new evidence also re-probes a transient unavailable answer")
    func evidenceBypassesUnavailable() async {
        let clock = Clock()
        let counter = Counter()
        counter.states = [.unavailable(reason: "devicectl exited 1: busy"), .active(sampleSession)]
        let monitor = makeMonitor(clock: clock, counter: counter)

        _ = await monitor.state(for: "A")
        #expect(await monitor.state(for: "A", evidence: resizedScene) == .active(sampleSession))
        #expect(counter.count == 2)
    }

    @Test("invalidate() forces the next query to re-probe")
    func invalidateReprobes() async {
        let clock = Clock()
        let counter = Counter()
        let monitor = makeMonitor(clock: clock, counter: counter)
        _ = await monitor.state(for: "A")
        await monitor.invalidate(udid: "A")
        _ = await monitor.state(for: "A")
        #expect(counter.count == 2)
    }

    @Test("a devicectl without the subcommand is remembered for the whole process")
    func missingSubcommandIsSticky() async {
        let clock = Clock()
        let counter = Counter()
        counter.states = [.unavailable(reason: "devicectl has no `device info appResize` subcommand (Xcode 27+ required)")]
        let monitor = makeMonitor(clock: clock, counter: counter)

        _ = await monitor.state(for: "A")
        clock.advance(60)
        guard case .unavailable(let reason) = await monitor.state(for: "B") else {
            Issue.record("expected .unavailable")
            return
        }
        #expect(reason.contains("subcommand"))
        #expect(counter.count == 1)
    }

    @Test("other unavailable reasons are not sticky — they expire with the TTL")
    func transientUnavailableIsNotSticky() async {
        let clock = Clock()
        let counter = Counter()
        counter.states = [.unavailable(reason: "devicectl exited 1: CoreDevice busy"), .inactive]
        let monitor = makeMonitor(clock: clock, counter: counter)

        _ = await monitor.state(for: "A")
        clock.advance(5.1)
        #expect(await monitor.state(for: "A") == .inactive)
        #expect(counter.count == 2)
    }

    @Test("SIM_USE_RESIZE_SESSION_CHECK=0 disables the probe entirely")
    func killSwitchSkipsProbe() async {
        let clock = Clock()
        let counter = Counter()
        let monitor = makeMonitor(clock: clock, counter: counter, environment: [ResizableAppSessionMonitor.disableEnvironmentKey: "0"])

        guard case .unavailable(let reason) = await monitor.state(for: "A") else {
            Issue.record("expected .unavailable")
            return
        }
        #expect(reason.contains(ResizableAppSessionMonitor.disableEnvironmentKey))
        #expect(counter.count == 0)
    }

    @Test("the probe runs regardless of the selected Xcode: another Xcode or Device Hub may own the session (R150-08)")
    func probesWithoutAnXcodeGate() async {
        // There is no version shortcut to inject or bypass: a capable
        // devicectl answering "active" must be believed on any toolchain.
        let clock = Clock()
        let counter = Counter()
        counter.states = [.active(sampleSession)]
        let monitor = makeMonitor(clock: clock, counter: counter)
        #expect(await monitor.state(for: "A") == .active(sampleSession))
        #expect(counter.count == 1)
    }
}

// MARK: - Guard, error, advisories

@Suite("ResizableAppSession — guard, error and advisories")
struct ResizableAppSessionGuardTests {
    private let quietLogger = SimUseLogger(writeToStdErr: false)

    private func monitor(returning state: ResizableAppSessionState) -> ResizableAppSessionMonitor {
        ResizableAppSessionMonitor(probe: { _ in state }, environment: [:])
    }

    @Test("an active session refuses the verb with the session attached")
    func activeSessionThrows() async {
        do {
            try await ResizableAppSessionGuard.assertTouchInputReachesApp(
                udid: "UDID-1", verb: "tap", logger: quietLogger, monitor: monitor(returning: .active(sampleSession))
            )
            Issue.record("expected ResizableAppSessionError")
        } catch let error as ResizableAppSessionError {
            #expect(error.verb == "tap")
            #expect(error.udid == "UDID-1")
            #expect(error.session == sampleSession)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("no session and an unavailable check both let the verb proceed")
    func inactiveAndUnavailableProceed() async throws {
        try await ResizableAppSessionGuard.assertTouchInputReachesApp(
            udid: "U", verb: "swipe", logger: quietLogger, monitor: monitor(returning: .inactive)
        )
        try await ResizableAppSessionGuard.assertTouchInputReachesApp(
            udid: "U", verb: "swipe", logger: quietLogger, monitor: monitor(returning: .unavailable(reason: "n/a"))
        )
    }

    @Test("an active session refuses main-display video capture with the capture error (R150-06)")
    func activeSessionRefusesCapture() async {
        do {
            try await ResizableAppSessionGuard.assertCaptureReachesApp(
                udid: "UDID-1", verb: "record-video", logger: quietLogger, monitor: monitor(returning: .active(sampleSession))
            )
            Issue.record("expected ResizableAppSessionCaptureError")
        } catch let error as ResizableAppSessionCaptureError {
            #expect(error.verb == "record-video")
            #expect(error.session == sampleSession)
            let message = error.localizedDescription
            #expect(message.contains("`record-video` captures only the main display"))
            #expect(message.contains("Nothing was captured."))
            #expect(message.contains("#143"))
            let hint = error.hint ?? ""
            #expect(hint.contains("xcrun simctl io UDID-1 recordVideo --display=0933D2CA-38DF-4B17-9934-7CDC624B355C"))
            #expect(hint.contains("`screenshot`, which is redirected"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
        // No session / unavailable: capture proceeds.
        try? await ResizableAppSessionGuard.assertCaptureReachesApp(
            udid: "U", verb: "stream-video", logger: quietLogger, monitor: monitor(returning: .inactive)
        )
        try? await ResizableAppSessionGuard.assertCaptureReachesApp(
            udid: "U", verb: "stream-video", logger: quietLogger, monitor: monitor(returning: .unavailable(reason: "n/a"))
        )
    }

    @Test("the error names the verb, the size, the issue and says nothing was sent")
    func errorMessage() {
        let error = ResizableAppSessionError(verb: "long-press", udid: "UDID-1", session: sampleSession)
        let message = error.localizedDescription
        #expect(message.contains("resizable app session"))
        #expect(message.contains("UDID-1"))
        #expect(message.contains("'Resizable' display (560x874 points requested)"))
        #expect(message.contains("this long-press would report success and deliver nothing"))
        #expect(message.contains("#143"))
        #expect(message.contains("No input was sent."))
    }

    @Test("the hint gives the way out and the escape hatch")
    func errorHint() throws {
        let hint = try #require(ResizableAppSessionError(verb: "tap", udid: "U", session: sampleSession).hint)
        #expect(hint.contains("devicectl device appResize start"))
        #expect(hint.contains("`type`, the key verbs and Cmd+V `paste` keep working"))
        #expect(hint.contains("`paste --via-menu` is a touch path and is refused"))
        #expect(hint.contains("\(ResizableAppSessionMonitor.disableEnvironmentKey)=0"))
    }

    @Test("describe-ui advisory reports scene, requested and main-display sizes")
    func describeUIAdvisory() {
        let advisory = ResizableAppSessionAdvisory.describeUI(
            session: sampleSession,
            sceneSize: (width: 437, height: 874),
            native: NativePortraitSize(width: 402, height: 874)
        )
        #expect(advisory.kind == .resizableAppSession)
        #expect(advisory.message.contains("437x874 points (requested 560x874 points)"))
        #expect(advisory.message.contains("main display is 402x874"))
        #expect(advisory.message.contains("recovery and orientation calibration were skipped"))
        #expect(advisory.message.contains("Touch paths (tap, long-press, swipe, touch, gesture, multi-touch, touch-bearing batch steps, paste --via-menu) and main-display video capture (record-video, stream-video) are refused"))
        #expect(advisory.message.contains("Cmd+V `paste` and `screenshot` work"))
    }

    @Test("describe-ui advisory degrades without scene or native sizes")
    func describeUIAdvisoryWithoutSizes() {
        let advisory = ResizableAppSessionAdvisory.describeUI(session: sampleSession, sceneSize: nil, native: nil)
        #expect(advisory.message.contains("at requested 560x874 points."))
        #expect(!advisory.message.contains("main display is"))
    }

    @Test("point-query and screenshot advisories carry the kind and the display")
    func pointAndScreenshotAdvisories() {
        let point = ResizableAppSessionAdvisory.pointQuery(session: sampleSession)
        #expect(point.kind == .resizableAppSession)
        #expect(point.message.contains("describes SpringBoard rather than the app"))

        let shot = ResizableAppSessionAdvisory.screenshot(session: sampleSession, pixelSize: (width: 1680, height: 2622))
        #expect(shot.kind == .resizableAppSession)
        #expect(shot.message.contains("Captured the 'Resizable' display (560x874 points requested, 1680x2622 px)"))

        let shotNoSize = ResizableAppSessionAdvisory.screenshot(session: sampleSession, pixelSize: nil)
        #expect(shotNoSize.message.contains("(560x874 points requested)"))
    }

    @Test("the advisory kind's wire value is stable")
    func advisoryKindRawValue() {
        #expect(CommandAdvisory.Kind.resizableAppSession.rawValue == "resizable_app_session")
    }

    @Test("fractional sizes are printed as-is, whole ones without a decimal")
    func sizeFormatting() {
        let fractional = ResizableAppSession(displayUniqueID: "d", displayName: "Resizable", preferredWidth: 437.5, preferredHeight: 874)
        #expect(fractional.preferredSizeDescription == "437.5x874")
    }
}

// MARK: - Screenshot redirection

@Suite("ResizableDisplayScreenshot — simctl capture of the Resizable display")
struct ResizableDisplayScreenshotTests {
    @Test("simctl argument vector selects the display by its CoreDevice UUID")
    func argumentsArePinned() {
        let args = ResizableDisplayScreenshot.arguments(
            udid: "ABC", displayUniqueID: "0933D2CA-38DF-4B17-9934-7CDC624B355C", destination: URL(fileURLWithPath: "/tmp/out.png")
        )
        #expect(args == ["simctl", "io", "ABC", "screenshot", "--type=png", "--display=0933D2CA-38DF-4B17-9934-7CDC624B355C", "/tmp/out.png"])
    }

    @Test("a simctl failure surfaces as a CLIError naming the display")
    func simctlFailureIsCLIError() {
        let destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("resizable-\(UUID().uuidString).png")
        do {
            _ = try ResizableDisplayScreenshot.capture(udid: "x", session: sampleSession, to: destination, executablePath: "/bin/false")
            Issue.record("expected a throw")
        } catch let error as CLIError {
            #expect(error.localizedDescription.contains("'Resizable' display (0933D2CA-38DF-4B17-9934-7CDC624B355C)"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("a silent simctl that writes no file is reported")
    func missingFileIsReported() {
        let destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("resizable-\(UUID().uuidString).png")
        do {
            _ = try ResizableDisplayScreenshot.capture(udid: "x", session: sampleSession, to: destination, executablePath: "/usr/bin/true")
            Issue.record("expected a throw")
        } catch let error as CLIError {
            #expect(error.localizedDescription.contains("wrote no screenshot"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("pixelSize reads a PNG's dimensions")
    func pixelSizeReadsPNG() throws {
        // 1x1 transparent PNG.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("px-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = try #require(ResizableDisplayScreenshot.pixelSize(of: url))
        #expect(size.width == 1)
        #expect(size.height == 1)
    }
}

// MARK: - In-band evidence (raw tree size vs device size)

@Suite("AccessibilityFetcher.resizedSceneEvidence")
struct SceneSizeEvidenceTests {
    private let iPhone17 = NativePortraitSize(width: 402, height: 874)

    private func tree(width: Double, height: Double, type: String = "Application") -> AnyObject {
        [["type": type, "role": "AXApplication", "frame": ["x": 0, "y": 0, "width": width, "height": height]]] as AnyObject
    }

    private func evidence(_ width: Double, _ height: Double, native: NativePortraitSize) -> ResizableAppSessionMonitor.SceneEvidence? {
        AccessibilityFetcher.resizedSceneEvidence(info: tree(width: width, height: height), native: native)
    }

    @Test("a resized scene is evidence carrying its size; the device's own size and its landscape swap are not")
    func resizedVersusDeviceSizes() {
        #expect(evidence(560, 874, native: iPhone17) == .init(width: 560, height: 874))
        #expect(evidence(375, 667, native: iPhone17) == .init(width: 375, height: 667))
        #expect(evidence(437, 874, native: iPhone17) == .init(width: 437, height: 874))
        #expect(evidence(402, 874, native: iPhone17) == nil)
        #expect(evidence(874, 402, native: iPhone17) == nil)
    }

    @Test("a scene proportional to the device is still evidence (R150-05) — only the device's own sizes are exempt")
    func proportionalScenesAreEvidence() {
        // 480x1044 is 402x874 scaled by ~1.194 on both axes — the shape
        // the reviewer used to slip a selector tap past a proportional
        // "panel downscale" classifier. It is a resized scene.
        #expect(evidence(480, 1044, native: iPhone17) == .init(width: 480, height: 1044))
        #expect(evidence(201, 437, native: iPhone17) == .init(width: 201, height: 437))
    }

    @Test("display-downscaled panels count as evidence too; the monitor's dedup, not the classifier, bounds their cost (R150-03)")
    func downscaledPanelsAreEvidenceDedupedByMonitor() async {
        // iPhone 12/13 mini: AX 375x812 over 1080x2340 px @3 = 360x780.
        let mini = NativePortraitSize(width: 360, height: 780)
        let miniEvidence = evidence(375, 812, native: mini)
        #expect(miniEvidence == .init(width: 375, height: 812))

        // Repeated fetches with that constant evidence probe once per TTL.
        let counter = ProbeCounter()
        let monitor = ResizableAppSessionMonitor(probe: { counter.record($0) }, environment: [:])
        for _ in 0..<5 { _ = await monitor.state(for: "mini", evidence: miniEvidence) }
        #expect(counter.count == 1)
    }

    private final class ProbeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        func record(_ udid: String) -> ResizableAppSessionState { lock.lock(); calls += 1; lock.unlock(); return .inactive }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    }

    @Test("rounding slack of one point is tolerated")
    func roundingSlack() {
        #expect(evidence(402.6, 873.4, native: iPhone17) == nil)
    }

    @Test("no screen info or no framed root means no evidence")
    func noEvidence() {
        #expect(evidence(560, 874, native: iPhone17) != nil)
        #expect(AccessibilityFetcher.resizedSceneEvidence(info: tree(width: 560, height: 874), native: nil) == nil)
        #expect(AccessibilityFetcher.resizedSceneEvidence(info: [["type": "Application", "role": "AXApplication"]] as AnyObject, native: iPhone17) == nil)
        #expect(AccessibilityFetcher.resizedSceneEvidence(info: [] as AnyObject, native: iPhone17) == nil)
    }
}

// MARK: - Batch step scan

@Suite("IOSSimBatchCommand — touch-step scan for the session guard")
struct BatchTouchStepScanTests {
    @Test("tap, swipe, gesture and touch count as touch steps")
    func touchKinds() {
        #expect(IOSSimBatchCommand.containsTouchStep(["type hello", "tap @1"]))
        #expect(IOSSimBatchCommand.containsTouchStep(["swipe --start-x 1 --start-y 2 --end-x 3 --end-y 4"]))
        #expect(IOSSimBatchCommand.containsTouchStep(["gesture scroll-up"]))
        #expect(IOSSimBatchCommand.containsTouchStep(["touch --down -x 1 -y 1"]))
    }

    @Test("keyboard-only batches are not touch batches")
    func keyboardKinds() {
        #expect(!IOSSimBatchCommand.containsTouchStep(["type hello", "key 40", "key-sequence 40 41", "key-combo 55 6", "paste x", "sleep 0.1"]))
        #expect(!IOSSimBatchCommand.containsTouchStep([]))
        #expect(!IOSSimBatchCommand.containsTouchStep(["'unterminated", "not-a-kind foo"]))
    }

    @Test("stepKind(of:) is the per-step classifier the loop gate uses (R150-02)")
    func stepKindOfLine() {
        #expect(IOSSimBatchCommand.stepKind(of: "tap @1") == .tap)
        #expect(IOSSimBatchCommand.stepKind(of: "  swipe --start-x 1 --start-y 2 --end-x 3 --end-y 4") == .swipe)
        #expect(IOSSimBatchCommand.stepKind(of: "type 'hello world'") == .type)
        #expect(IOSSimBatchCommand.stepKind(of: "sleep 0.5") == .sleep)
        #expect(IOSSimBatchCommand.stepKind(of: "") == nil)
        #expect(IOSSimBatchCommand.stepKind(of: "'unterminated") == nil)
        #expect(IOSSimBatchCommand.stepKind(of: "not-a-kind foo") == nil)
        for kind in IOSSimBatchCommand.touchStepKinds {
            #expect(IOSSimBatchCommand.stepKind(of: "\(kind.rawValue) --x 1") == kind)
        }
    }
}
