// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

// Unit coverage for display topology, routing display resolution and the
// fold / rotate planning (docs/ai/010-display-routing). The devicectl
// documents under Fixtures/display-topology were captured live on
// Xcode 27.0 devicectl 651.13.5: iPhone 17 / iOS 27.0, and iPhone Duo /
// iOS 27.1 folded and unfolded.

private func fixture(_ name: String) throws -> DevicectlQueryOutput {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/display-topology/\(name)", withExtension: "json"))
    return DevicectlQueryOutput(terminationStatus: 0, stdout: try Data(contentsOf: url), stderr: Data())
}

private func topology(_ name: String) throws -> SimulatorDisplayTopology {
    try #require(SimulatorDisplayTopologyProbe.classify(try fixture(name)).topology)
}

private let quietLogger = SimUseLogger(writeToStdErr: false)

private let session = ResizableAppSession(
    displayUniqueID: "7C42B556-2B95-4526-B558-C06CDA5AF3F7",
    displayName: "Resizable",
    preferredWidth: 560,
    preferredHeight: 874
)

private func topologyMonitor(_ state: SimulatorDisplayTopologyState) -> SimulatorDisplayTopologyMonitor {
    SimulatorDisplayTopologyMonitor(probe: { _ in state }, environment: [:])
}

private func sessionMonitor(_ state: ResizableAppSessionState) -> ResizableAppSessionMonitor {
    ResizableAppSessionMonitor(probe: { _ in state }, environment: [:])
}

// MARK: - Probe

@Suite("SimulatorDisplayTopologyProbe — devicectl document decoding")
struct SimulatorDisplayTopologyProbeTests {
    @Test("iPhone 17: one integrated display (no `active` key) plus the virtual Resizable canvas")
    func singleDisplay() throws {
        let topology = try topology("iphone17")
        #expect(topology.displays.count == 2)
        #expect(topology.integratedDisplays.map(\.name) == ["LCD"])
        #expect(!topology.isMultiDisplay)
        #expect(topology.activeIntegrated == nil)
        #expect(topology.primary?.name == "LCD")
        let resizable = try #require(topology.displays.first { $0.name == "Resizable" })
        #expect(resizable.kind == .virtual)
        #expect(resizable.displayID == 4)
        #expect(resizable.panelPoints == NativePortraitSize(width: 2560, height: 1440))
    }

    @Test("iPhone Duo folded: the primary cover display is active")
    func duoFolded() throws {
        let topology = try topology("duo-folded")
        #expect(topology.isMultiDisplay)
        let active = try #require(topology.activeIntegrated)
        #expect(active.name == "LCD")
        #expect(active.isPrimary)
        #expect(active.displayID == 1)
        #expect(active.panelPoints == NativePortraitSize(width: 466, height: 678))
        #expect(topology.deviceOrientation == "portrait")
    }

    @Test("iPhone Duo unfolded: the inner display is active at rot90, reported with device landscapeRight")
    func duoOpen() throws {
        let topology = try topology("duo-open")
        let active = try #require(topology.activeIntegrated)
        #expect(active.name == "LCD-1")
        #expect(!active.isPrimary)
        #expect(active.displayID == 3)
        #expect(active.rotation == .rot90)
        #expect(active.backlightState == "activeOn")
        #expect(active.panelPoints == NativePortraitSize(width: 669, height: 951))
        #expect(topology.deviceOrientation == "landscapeRight")
        let cover = try #require(topology.primary)
        #expect(cover.name == "LCD")
        #expect(cover.backlightState == "off")
    }

    @Test("iOS 26.5 runtime: no uniqueId, no Resizable display — the name stands in for the UUID")
    func preIOS27Runtime() throws {
        let topology = try topology("iphone17-ios26-landscape")
        #expect(topology.displays.count == 1)
        let lcd = try #require(topology.primary)
        #expect(lcd.uniqueID == "LCD")
        #expect(lcd.rotation == .rot90)
        #expect(lcd.backlightState == "unknown")
        #expect(topology.deviceOrientation == "landscapeRight")
        #expect(!topology.isMultiDisplay)
    }

    @Test("an error document is unavailable and names the code")
    func errorDocument() {
        let document = """
        {"error":{"code":1000,"domain":"com.apple.dt.CoreDeviceError","userInfo":{"NSLocalizedDescription":{"string":"The specified device was not found."}}},"info":{"outcome":"failed"}}
        """
        let state = SimulatorDisplayTopologyProbe.classify(DevicectlQueryOutput(terminationStatus: 1, stdout: Data(document.utf8), stderr: Data()))
        guard case .unavailable(let reason) = state else {
            Issue.record("expected unavailable, got \(state)")
            return
        }
        #expect(reason.contains("1000"))
        #expect(reason.contains("not found"))
    }

    @Test("a devicectl without the subcommand is unavailable and says so")
    func unknownSubcommand() {
        let state = SimulatorDisplayTopologyProbe.classify(DevicectlQueryOutput(
            terminationStatus: 64, stdout: Data(), stderr: Data("Error: Unknown subcommand 'displays'".utf8)
        ))
        #expect(state == .unavailable(reason: "devicectl has no `device info displays` subcommand"))
    }

    @Test("entries without an id or a size are dropped; none left is unavailable")
    func unreadableEntries() {
        let document = """
        {"result":{"displays":[{"name":"x","bounds":[[0,0],[1,1]]},{"displayId":1,"uniqueId":"U"}]}}
        """
        let state = SimulatorDisplayTopologyProbe.classify(DevicectlQueryOutput(terminationStatus: 0, stdout: Data(document.utf8), stderr: Data()))
        #expect(state == .unavailable(reason: "devicectl listed no readable display"))
    }

    @Test("devicectl argument vector is pinned")
    func arguments() {
        #expect(SimulatorDisplayTopologyProbe.arguments(udid: "ABC") == [
            "devicectl", "device", "info", "displays", "--device", "ABC", "--json-output", "-", "--timeout", "5", "--quiet",
        ])
    }
}

// MARK: - Monitor

@Suite("SimulatorDisplayTopologyMonitor — caching")
struct SimulatorDisplayTopologyMonitorTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var now = Date(timeIntervalSince1970: 0)
        func advance(_ seconds: TimeInterval) { lock.lock(); now += seconds; lock.unlock() }
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return now }
    }

    @Test("a single-display answer is kept for the life of the process")
    func singleDisplayIsPermanent() async throws {
        let clock = Clock()
        let state = SimulatorDisplayTopologyState.available(try topology("iphone17"))
        let monitor = SimulatorDisplayTopologyMonitor(ttl: 2, clock: { clock.read() }, probe: { _ in state }, environment: [:])
        _ = await monitor.state(for: "U")
        clock.advance(3600)
        _ = await monitor.state(for: "U")
        #expect(await monitor.probeCount == 1)
    }

    @Test("a multi-display answer expires with the TTL; fresh and invalidate re-probe")
    func multiDisplayExpires() async throws {
        let clock = Clock()
        let state = SimulatorDisplayTopologyState.available(try topology("duo-open"))
        let monitor = SimulatorDisplayTopologyMonitor(ttl: 2, clock: { clock.read() }, probe: { _ in state }, environment: [:])
        _ = await monitor.state(for: "U")
        _ = await monitor.state(for: "U")
        #expect(await monitor.probeCount == 1)
        clock.advance(2.5)
        _ = await monitor.state(for: "U")
        #expect(await monitor.probeCount == 2)
        _ = await monitor.state(for: "U", fresh: true)
        #expect(await monitor.probeCount == 3)
        await monitor.invalidate(udid: "U")
        _ = await monitor.state(for: "U")
        #expect(await monitor.probeCount == 4)
    }

    @Test("a fresh query bypasses the permanent single-display answer")
    func freshBypassesSingleDisplay() async throws {
        let state = SimulatorDisplayTopologyState.available(try topology("iphone17"))
        let monitor = SimulatorDisplayTopologyMonitor(probe: { _ in state }, environment: [:])
        _ = await monitor.state(for: "U")
        _ = await monitor.state(for: "U", fresh: true)
        #expect(await monitor.probeCount == 2)
    }

    @Test("a missing subcommand is remembered; SIM_USE_DISPLAY_TOPOLOGY_CHECK=0 disables the probe")
    func stickyAndDisabled() async {
        let missing = SimulatorDisplayTopologyMonitor(
            probe: { _ in .unavailable(reason: "devicectl has no `device info displays` subcommand") }, environment: [:]
        )
        _ = await missing.state(for: "A")
        _ = await missing.state(for: "B", fresh: true)
        #expect(await missing.probeCount == 1)

        let disabled = SimulatorDisplayTopologyMonitor(
            probe: { _ in Issue.record("probe must not run"); return .unavailable(reason: "x") },
            environment: [SimulatorDisplayTopologyMonitor.disableEnvironmentKey: "0"]
        )
        guard case .unavailable(let reason) = await disabled.state(for: "A") else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains("disabled"))
    }
}

// MARK: - Resolution

@Suite("RoutingDisplayResolver — which display hosts the app")
struct RoutingDisplayResolverTests {
    @Test("a Resize Mode session wins and finds its display in the topology")
    func sessionWins() throws {
        let routing = RoutingDisplayResolver.resolve(session: .active(session), topology: .available(try topology("duo-open")))
        guard case .resizable(let resolved, let display) = routing else {
            Issue.record("expected resizable, got \(routing)")
            return
        }
        #expect(resolved == session)
        #expect(display?.displayID == 5)
        #expect(routing.captureUniqueID == session.displayUniqueID)
    }

    @Test("unfolded Duo routes to the inner display; folded Duo and iPhone stay on main")
    func integratedDisplays() throws {
        let open = RoutingDisplayResolver.resolve(session: .inactive, topology: .available(try topology("duo-open")))
        guard case .secondary(let display) = open else {
            Issue.record("expected secondary, got \(open)")
            return
        }
        #expect(display.name == "LCD-1")
        #expect(open.interfaceOrientation == .landscapeLeft)
        #expect(open.panelPoints == NativePortraitSize(width: 669, height: 951))

        #expect(RoutingDisplayResolver.resolve(session: .inactive, topology: .available(try topology("duo-folded"))) == .main)
        #expect(RoutingDisplayResolver.resolve(session: .inactive, topology: .available(try topology("iphone17"))) == .main)
        #expect(RoutingDisplayResolver.resolve(session: .unavailable(reason: "x"), topology: .unavailable(reason: "y")) == .main)
    }

    @Test("off the main display, describe-ui gets a display object and a header tag; on main, neither")
    func infoAndTag() throws {
        let open = RoutingDisplayResolver.resolve(session: .inactive, topology: .available(try topology("duo-open")))
        #expect(open.headerTag == "display LCD-1")
        #expect(open.info == RoutingDisplayInfo(name: "LCD-1", id: 3, kind: "integrated", primary: false, rotation: "rot90", resizableSession: nil))

        let resized = RoutingDisplayResolver.resolve(session: .active(session), topology: .available(try topology("iphone17")))
        // The iPhone 17 fixture's Resizable display has another UUID, so
        // the entry is not found and the session's own name is used.
        #expect(resized.headerTag == "display Resizable 560x874")
        #expect(resized.info?.resizableSession == .init(preferredWidth: 560, preferredHeight: 874))
        #expect(resized.info?.kind == "virtual")

        #expect(RoutingDisplay.main.info == nil)
        #expect(RoutingDisplay.main.headerTag == nil)
    }

    @Test("the display object encodes without a resizableSession key when there is none")
    func infoEncoding() throws {
        let info = RoutingDisplayInfo(name: "LCD-1", id: 3, kind: "integrated", primary: false, rotation: "rot90", resizableSession: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(info), as: UTF8.self)
        #expect(json == #"{"id":3,"kind":"integrated","name":"LCD-1","primary":false,"rotation":"rot90"}"#)
    }
}

// MARK: - Guard

@Suite("RoutingDisplayGuard — refusals off the main display")
struct RoutingDisplayGuardTests {
    @Test("a secondary display lets touch through (routed) and refuses main-display capture")
    func secondaryRoutesTouchRefusesCapture() async throws {
        let topologyState = SimulatorDisplayTopologyState.available(try topology("duo-open"))
        try await RoutingDisplayGuard.assertTouchInputReachesApp(
            udid: "U", verb: "tap", logger: quietLogger,
            sessionMonitor: sessionMonitor(.inactive), topologyMonitor: topologyMonitor(topologyState)
        )
        do {
            try await RoutingDisplayGuard.assertCaptureReachesApp(
                udid: "U", verb: "record-video", logger: quietLogger,
                sessionMonitor: sessionMonitor(.inactive), topologyMonitor: topologyMonitor(topologyState)
            )
            Issue.record("expected SecondaryDisplayCaptureError")
        } catch let error as SecondaryDisplayCaptureError {
            #expect(error.localizedDescription.contains("Nothing was captured."))
            #expect(error.hint?.contains("--display=37AFD618-C3EB-415F-AC4B-ABA9E4D465CF") == true)
        }
    }

    @Test("folded Duo and a single-display iPhone proceed")
    func mainProceeds() async throws {
        for name in ["duo-folded", "iphone17"] {
            try await RoutingDisplayGuard.assertTouchInputReachesApp(
                udid: "U", verb: "tap", logger: quietLogger,
                sessionMonitor: sessionMonitor(.inactive), topologyMonitor: topologyMonitor(.available(try topology(name)))
            )
        }
    }

    @Test("every refusal is a RoutingDisplayRefusal, so batch rethrows it unchanged")
    func refusalProtocol() throws {
        let display = try #require(try topology("duo-open").activeIntegrated)
        let refusals: [any Error] = [
            SecondaryDisplayCaptureError(verb: "record-video", udid: "U", display: display),
            ResizableAppSessionCaptureError(verb: "record-video", udid: "U", session: session),
        ]
        for refusal in refusals {
            #expect(refusal is any RoutingDisplayRefusal)
        }
    }
}

// MARK: - Geometry

@Suite("SimulatorDisplayRotation — interface orientation and the measured panel mapping")
struct SimulatorDisplayRotationTests {
    /// The normalized panel point measured live for a UI point on the Duo
    /// inner display (plan E4; W = 669, H = 951).
    private func measured(_ rotation: SimulatorDisplayRotation, _ x: Double, _ y: Double) -> CGPoint {
        let w = 669.0, h = 951.0
        switch rotation {
        case .rot0: return CGPoint(x: x / w, y: y / h)
        case .rot90: return CGPoint(x: y / w, y: 1 - x / h)
        case .rot180: return CGPoint(x: 1 - x / w, y: 1 - y / h)
        case .rot270: return CGPoint(x: 1 - y / w, y: x / h)
        }
    }

    @Test("rotations map to sim-use interface orientation names", arguments: [
        (SimulatorDisplayRotation.rot0, DisplayOrientation.portrait),
        (.rot90, .landscapeLeft),
        (.rot180, .portraitUpsideDown),
        (.rot270, .landscapeRight),
    ])
    func names(rotation: SimulatorDisplayRotation, orientation: DisplayOrientation) {
        #expect(rotation.interfaceOrientation == orientation)
    }

    @Test("DisplayOrientation.uiToFramebuffer reproduces the measured mapping for every rotation", arguments: SimulatorDisplayRotation.allCases)
    func mappingMatchesMeasurement(rotation: SimulatorDisplayRotation) {
        let native = NativePortraitSize(width: 669, height: 951)
        let orientation = rotation.interfaceOrientation
        let ui = orientation.uiSize(native: native)
        for (x, y) in [(42.0, 42.0), (603.5, 179.7), (ui.width / 2, ui.height / 2), (100.0, 400.0)] {
            let panel = orientation.uiToFramebuffer(CGPoint(x: x, y: y), native: native)
            let expected = measured(rotation, x, y)
            #expect(abs(panel.x / 669 - expected.x) < 1e-9)
            #expect(abs(panel.y / 951 - expected.y) < 1e-9)
        }
    }
}

// MARK: - Fold

@Suite("FoldTarget — argument parsing and expectations")
struct FoldTargetTests {
    @Test("names and angles parse", arguments: [
        ("closed", 0.0), ("close", 0.0), ("folded", 0.0),
        ("open", 180.0), ("flat", 180.0), ("unfolded", 180.0),
        ("half", 130.0), ("half-open", 130.0),
        ("0", 0.0), ("95.5", 95.5), ("180", 180.0),
    ])
    func parses(argument: String, degrees: Double) throws {
        #expect(try #require(FoldTarget(argument: argument)).degrees == degrees)
    }

    @Test("out-of-range and unknown arguments are rejected", arguments: ["-1", "181", "nan", "inf", "sideways", ""])
    func rejects(argument: String) {
        #expect(FoldTarget(argument: argument) == nil)
    }

    @Test("only 0° and 180° carry an expectation (the result in between depends on the path)")
    func expectations() {
        #expect(FoldTarget.closed.expectation == .primaryActive)
        #expect(FoldTarget.degrees(0).expectation == .primaryActive)
        #expect(FoldTarget.open.expectation == .secondaryActive)
        #expect(FoldTarget.degrees(180).expectation == .secondaryActive)
        #expect(FoldTarget.half.expectation == .observeOnly)
        #expect(FoldTarget.degrees(45).expectation == .observeOnly)
    }

    @Test("expectations read the active flag of the fixtures")
    func expectationsAgainstFixtures() throws {
        let folded = try topology("duo-folded")
        let open = try topology("duo-open")
        #expect(FoldExpectation.primaryActive.isMet(by: folded))
        #expect(!FoldExpectation.primaryActive.isMet(by: open))
        #expect(FoldExpectation.secondaryActive.isMet(by: open))
        #expect(!FoldExpectation.secondaryActive.isMet(by: folded))
    }

    @Test("the posture summary names the active display and the other integrated displays")
    func postureSummary() throws {
        let report = PostureReport(topology: try topology("duo-open"), session: nil)
        #expect(report.summary == "active display LCD-1 (id 3), landscape-left; integrated displays: LCD, LCD-1; device orientation landscapeRight")
        let single = PostureReport(topology: try topology("iphone17"), session: session)
        #expect(single.activeDisplay?.name == "LCD")
        #expect(single.summary.contains("Resize Mode session 560x874"))
        #expect(!single.summary.contains("integrated displays"))
    }
}

// MARK: - Rotate

@Suite("RotationPlanner — device orientation and transport offset")
struct RotationPlannerTests {
    @Test("interface orientation → device orientation (devicectl convention)", arguments: [
        (DisplayOrientation.portrait, DeviceOrientationValue.portrait),
        (.landscapeLeft, .landscapeRight),
        (.portraitUpsideDown, .portraitUpsideDown),
        (.landscapeRight, .landscapeLeft),
    ])
    func deviceOrientation(target: DisplayOrientation, device: DeviceOrientationValue) {
        #expect(RotationPlanner.deviceOrientation(for: target) == device)
    }

    @Test("the initial transport offset is 0 on a primary display and 1 on a secondary one")
    func initialOffset() throws {
        let open = try topology("duo-open")
        #expect(RotationPlanner.initialTransportOffset(display: open.activeIntegrated) == 1)
        #expect(RotationPlanner.initialTransportOffset(display: open.primary) == 0)
        #expect(RotationPlanner.initialTransportOffset(display: nil) == 0)
    }

    /// Measured on the unfolded Duo: each orientation picker value read
    /// back one quarter turn further (plan E2).
    @Test("with offset 1 the sent picker value reproduces the measured read-back", arguments: [
        (DeviceOrientationValue.portrait, "landscapeRight"),
        (.landscapeLeft, "portrait"),
        (.portraitUpsideDown, "landscapeLeft"),
        (.landscapeRight, "portraitUpsideDown"),
    ])
    func measuredOffset(sent: DeviceOrientationValue, reported: String) throws {
        #expect(RotationPlanner.learnedTransportOffset(sent: sent, reported: reported) == 1)
        let wanted = try #require(DeviceOrientationValue(rawValue: reported))
        #expect(RotationPlanner.sendValue(for: wanted, transportOffset: 1) == sent)
        #expect(RotationPlanner.sendValue(for: wanted, transportOffset: 0) == wanted)
    }

    @Test("flat and unknown reports teach nothing")
    func unlearnable() {
        #expect(RotationPlanner.learnedTransportOffset(sent: .portrait, reported: "faceUp") == nil)
        #expect(RotationPlanner.learnedTransportOffset(sent: .portrait, reported: "unknown") == nil)
    }

    @Test("Purple numbers landscape in interface style, so device left and right swap")
    func purpleMapping() {
        #expect(DeviceOrientationValue.portrait.purpleOrientation == .portrait)
        #expect(DeviceOrientationValue.portraitUpsideDown.purpleOrientation == .portraitUpsideDown)
        #expect(DeviceOrientationValue.landscapeLeft.purpleOrientation == .landscapeRight)
        #expect(DeviceOrientationValue.landscapeRight.purpleOrientation == .landscapeLeft)
    }
}

// MARK: - Vendor report

@Suite("VirtualMachineControl — the report Device Hub sends")
struct VirtualMachineControlTests {
    @Test("hinge and orientation payloads carry upstream idb's keys")
    func payloads() {
        let hinge = VirtualMachineControl.hinge(degrees: 130).payload
        #expect(hinge["provider"] as? String == "com.apple.Virtualization.VirtualMachines")
        #expect(hinge["source"] as? String == "hinge-slider-control")
        #expect(hinge["type"] as? String == "range")
        #expect(hinge["value"] as? Double == 130)

        let orientation = VirtualMachineControl.orientation(.portraitUpsideDown).payload
        #expect(orientation["source"] as? String == "orientation-picker-control")
        #expect(orientation["type"] as? String == "enum")
        #expect(orientation["value"] as? String == "pud")
        #expect(DeviceOrientationValue.landscapeLeft.virtualMachineValue.rawValue == "landscape-left")
    }

    @Test("the payload serialises as an IOKit binary property list")
    func binarySerialisation() throws {
        let data = try VirtualMachineControl.hinge(degrees: 0).serializedPayload()
        // OSSerializeBinary signature, little endian.
        #expect(Array(data.prefix(4)) == [0xD3, 0x00, 0x00, 0x00])
        #expect(VirtualMachineControl.usagePage == 0xFF61)
        #expect(VirtualMachineControl.usage == 0x5B)
    }
}

// MARK: - Outline header

@Suite("OutlineFormatter — display tag and interface size")
struct OutlineDisplayTagTests {
    private func tree(width: Double, height: Double) throws -> [AccessibilityElement] {
        let json = """
        [{"type":"Application","AXLabel":"Settings","frame":{"x":0,"y":0,"width":\(width),"height":\(height)},
          "children":[{"type":"Button","AXLabel":"About","frame":{"x":340,"y":304,"width":527,"height":52}}]}]
        """
        return try JSONDecoder().decode([AccessibilityElement].self, from: Data(json.utf8))
    }

    @Test("a secondary display tags the header and uses the interface size, not the root frame")
    func secondaryHeader() throws {
        let outline = OutlineFormatter.render(
            tree: try tree(width: 669, height: 951),
            orientationTag: "landscape-left",
            displayTag: "display LCD-1",
            screenSize: (width: 951, height: 669)
        )
        #expect(outline.text.hasPrefix("App: Settings  951x669  (landscape-left, display LCD-1)\n"))
        #expect(outline.screen.width == 951)
        #expect(outline.screen.height == 669)
    }

    @Test("without the new arguments the header is unchanged")
    func legacyHeader() throws {
        let outline = OutlineFormatter.render(tree: try tree(width: 402, height: 874))
        #expect(outline.text.hasPrefix("App: Settings  402x874\n"))
    }
}

// MARK: - Outline cache

@Suite("OutlineCache.invalidate")
struct OutlineCacheInvalidateTests {
    @Test("removes the snapshot so the next read is `missing`; a second call is harmless")
    func invalidate() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("outline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let payload = OutlineCache.Payload(
            version: OutlineCache.currentVersion, udid: "U", capturedAt: "2026-10-16T00:00:00Z",
            screen: .init(width: 1, height: 1), entries: []
        )
        try OutlineCache.writePayload(payload, udid: "U", home: home)
        #expect(throws: Never.self) { try OutlineCache.read(udid: "U", home: home) }
        OutlineCache.invalidate(udid: "U", home: home)
        OutlineCache.invalidate(udid: "U", home: home)
        #expect(throws: OutlineCache.ReadError.self) { try OutlineCache.read(udid: "U", home: home) }
    }
}

// MARK: - Cached state after a posture change (R157-01)

@Suite("PostureController — cached routing state after a posture change")
struct PostureCacheRefreshTests {
    /// Answers `first` on the first probe and `.inactive` after it: a
    /// session that a fold ended.
    final class EndingSession: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let first: ResizableAppSessionState
        init(first: ResizableAppSessionState) { self.first = first }
        func probe() -> ResizableAppSessionState {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return calls == 1 ? first : .inactive
        }
    }

    @Test("a fold re-reads the Resize Mode session instead of reporting the cached one")
    func foldRefreshesSession() async throws {
        let ending = EndingSession(first: .active(session))
        let sessions = ResizableAppSessionMonitor(probe: { _ in ending.probe() }, environment: [:])
        let topologies = topologyMonitor(.available(try topology("duo-open")))
        #expect(await sessions.state(for: "U").session == session) // warm cache
        let now = await PostureController.postureChanged(udid: "U", topologyMonitor: topologies, sessionMonitor: sessions)
        #expect(now == nil)
        guard case .secondary = await RoutingDisplayResolver.current(udid: "U", sessionMonitor: sessions, topologyMonitor: topologies) else {
            Issue.record("expected the inner display after the session ended")
            return
        }
    }

    @Test("rotate checks CoreDevice for a session, not a cached answer")
    func rotateRechecksSession() async throws {
        let ending = EndingSession(first: .active(session))
        let sessions = ResizableAppSessionMonitor(probe: { _ in ending.probe() }, environment: [:])
        #expect(await sessions.state(for: "U").session == session) // warm cache
        try await PostureController.assertNoResizeSession(udid: "U", sessionMonitor: sessions)
    }
}

// MARK: - AX root evidence refreshes the topology (R157-02)

@Suite("SimulatorDisplayTopologyMonitor — AX root size refreshes a multi-display answer")
struct TopologyRootEvidenceTests {
    final class Fixtures: @unchecked Sendable {
        private let lock = NSLock()
        private var current: SimulatorDisplayTopologyState
        init(_ state: SimulatorDisplayTopologyState) { current = state }
        func set(_ state: SimulatorDisplayTopologyState) { lock.lock(); current = state; lock.unlock() }
        func get() -> SimulatorDisplayTopologyState { lock.lock(); defer { lock.unlock() }; return current }
    }

    private typealias RootSize = SimulatorDisplayTopologyMonitor.RootSize

    @Test("an unfold seen in a new AX root re-probes inside the TTL and routes to the inner display")
    func newRootReprobes() async throws {
        let device = Fixtures(.available(try topology("duo-folded")))
        let frozen = Date(timeIntervalSince1970: 0)
        let topologies = SimulatorDisplayTopologyMonitor(ttl: 60, clock: { frozen }, probe: { _ in device.get() }, environment: [:])
        let sessions = sessionMonitor(.inactive)

        // Folded: the cover's root warms the cache.
        let folded = await RoutingDisplayResolver.current(
            udid: "U", rootSize: RootSize(width: 466, height: 678), sessionMonitor: sessions, topologyMonitor: topologies
        )
        #expect(folded == .main)
        #expect(await topologies.probeCount == 1)

        // Unfolded out of band; the next fetch sees the inner root.
        device.set(.available(try topology("duo-open")))
        let open = await RoutingDisplayResolver.current(
            udid: "U", rootSize: RootSize(width: 669, height: 951), sessionMonitor: sessions, topologyMonitor: topologies
        )
        guard case .secondary(let display) = open else {
            Issue.record("expected the inner display, got \(open)")
            return
        }
        #expect(display.name == "LCD-1")
        #expect(open.interfaceOrientation == .landscapeLeft)
        #expect(await topologies.probeCount == 2)

        // Touch input now goes to the inner display's digitizer.
        let route = try #require(try open.hidRoute())
        #expect(route.digitizerTarget == 3)

        // The same root again rides the cache.
        _ = await RoutingDisplayResolver.current(
            udid: "U", rootSize: RootSize(width: 669, height: 951), sessionMonitor: sessions, topologyMonitor: topologies
        )
        #expect(await topologies.probeCount == 2)

        // Folding back changes the root again (inner → cover) and re-probes.
        device.set(.available(try topology("duo-folded")))
        let back = await RoutingDisplayResolver.current(
            udid: "U", rootSize: RootSize(width: 466, height: 678), sessionMonitor: sessions, topologyMonitor: topologies
        )
        #expect(back == .main)
        #expect(await topologies.probeCount == 3)
    }

    @Test("a rootless probe that sees another active display drops the old root association (R157-02 follow-up)")
    func rootlessProbeDropsStaleRoot() async throws {
        let device = Fixtures(.available(try topology("duo-open")))
        let frozen = Date(timeIntervalSince1970: 0)
        let topologies = SimulatorDisplayTopologyMonitor(ttl: 60, clock: { frozen }, probe: { _ in device.get() }, environment: [:])
        let sessions = sessionMonitor(.inactive)
        let inner = RootSize(width: 669, height: 951)

        // Inner display active; `ui` warms the cache with the inner root.
        _ = await RoutingDisplayResolver.current(udid: "U", rootSize: inner, sessionMonitor: sessions, topologyMonitor: topologies)
        #expect(await topologies.probeCount == 1)

        // Folded out of band; a posture report probes without a root.
        device.set(.available(try topology("duo-folded")))
        _ = await topologies.state(for: "U", fresh: true)
        #expect(await topologies.probeCount == 2)

        // Unfolded again; the next `ui` brings the inner root back. The
        // cached cover answer must not ride on the old inner root.
        device.set(.available(try topology("duo-open")))
        let routing = await RoutingDisplayResolver.current(udid: "U", rootSize: inner, sessionMonitor: sessions, topologyMonitor: topologies)
        #expect(await topologies.probeCount == 3)
        guard case .secondary(let display) = routing else {
            Issue.record("expected the inner display, got \(routing)")
            return
        }
        #expect(display.name == "LCD-1")
        #expect(routing.interfaceOrientation == .landscapeLeft)
        #expect(try routing.hidRoute()?.digitizerTarget == 3)
    }

    @Test("a rootless probe that sees the same active display keeps the root association")
    func rootlessProbeKeepsValidRoot() async throws {
        let frozen = Date(timeIntervalSince1970: 0)
        let state = SimulatorDisplayTopologyState.available(try topology("duo-open"))
        let topologies = SimulatorDisplayTopologyMonitor(ttl: 60, clock: { frozen }, probe: { _ in state }, environment: [:])
        let inner = RootSize(width: 669, height: 951)
        _ = await topologies.state(for: "U", rootSize: inner)
        _ = await topologies.state(for: "U", fresh: true)
        _ = await topologies.state(for: "U", rootSize: inner)
        #expect(await topologies.probeCount == 2)
    }

    @Test("a single-display answer stays permanent whatever the root size")
    func singleDisplayIgnoresRoot() async throws {
        let topologies = SimulatorDisplayTopologyMonitor(probe: { _ in .available(try! topology("iphone17")) }, environment: [:])
        _ = await topologies.state(for: "U", rootSize: RootSize(width: 402, height: 874))
        _ = await topologies.state(for: "U", rootSize: RootSize(width: 560, height: 874))
        _ = await topologies.state(for: "U", rootSize: RootSize(width: 874, height: 402))
        #expect(await topologies.probeCount == 1)
    }
}
