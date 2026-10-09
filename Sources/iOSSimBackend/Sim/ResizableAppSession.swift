// SPDX-License-Identifier: Apache-2.0
import Foundation
import ImageIO
import SimUseCore

// MARK: - Model

/// An Xcode 27 "resizable app session" (Resize Mode) on a booted iOS 27+
/// simulator. Device Hub — or `xcrun devicectl device appResize start` —
/// moves the frontmost app onto a *virtual* display named "Resizable" and
/// hands it an arbitrary logical size; the main display keeps showing
/// SpringBoard (in practice just the wallpaper).
///
/// Every simulator primitive sim-use drives is bound to the main display:
/// HID touch is normalised against the main screen and sent to digitizer
/// target 0, the framebuffer picks `displayClass == 0`, and the AX
/// hit-test XPC resolves points against the main display even though the
/// AX tree fetch follows the frontmost app. During a session that makes
/// taps silent no-ops, screenshots capture wallpaper, and hit-test based
/// recovery splices SpringBoard nodes into the app's tree (issue #143).
///
/// This file is the stop-gap: *detect* the session via CoreDevice and make
/// every affected verb honest about it. Real routing to the Resizable
/// display needs upstream idb's multi-display plumbing — see
/// docs/ai/xxxx-resizable-app-session/README.md for the evidence, the
/// `touchscreen(0x104)` digitizer finding and the migration notes.
public struct ResizableAppSession: Equatable, Sendable {
    /// CoreDevice display UUID. **Changes on every boot** — never persist it.
    public let displayUniqueID: String
    /// `"Resizable"` on every observed runtime; carried for messages.
    public let displayName: String
    /// The size the session was asked for, in points. CoreDevice reports
    /// the *display's* preferred size, which the app's scene may snap away
    /// from (402x874 came back as 437x874 live); `describe-ui`'s `App:`
    /// header is the only place the scene's actual size is visible.
    public let preferredWidth: Double
    public let preferredHeight: Double

    public init(displayUniqueID: String, displayName: String, preferredWidth: Double, preferredHeight: Double) {
        self.displayUniqueID = displayUniqueID
        self.displayName = displayName
        self.preferredWidth = preferredWidth
        self.preferredHeight = preferredHeight
    }

    var preferredSizeDescription: String {
        "\(Self.format(preferredWidth))x\(Self.format(preferredHeight))"
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

public enum ResizableAppSessionState: Equatable, Sendable {
    case active(ResizableAppSession)
    /// CoreDevice answered: no session on this simulator (error 24004).
    case inactive
    /// CoreDevice could not answer — devicectl lacks the subcommand, the
    /// simulator is unknown to CoreDevice, the spawn failed or timed out,
    /// or the check is disabled. Callers proceed as if no session exists;
    /// the reason is logged, never surfaced as an error.
    case unavailable(reason: String)

    public var session: ResizableAppSession? {
        if case .active(let session) = self { return session }
        return nil
    }
}

// MARK: - Probe (devicectl)

/// Asks CoreDevice for the session state. Nothing in CoreSimulator tells a
/// session from no session: the Resizable display and its IO port stay
/// enumerated after a session ends, and its backlight reads `off` even
/// while one is active (verified on Xcode 27.0 / iOS 27.0). `devicectl
/// device info appResize` is the authoritative signal and costs ~0.3 s,
/// which is why `ResizableAppSessionMonitor` caches it.
public enum ResizableAppSessionProbe {
    /// Pinned by test. `--json-output -` puts the document on stdout and
    /// routes devicectl's own progress lines to stderr; `--quiet` trims
    /// those further. The 5 s timeout bounds a wedged CoreDevice.
    public static func arguments(udid: String) -> [String] {
        [
            "devicectl", "device", "info", "appResize",
            "--device", udid,
            "--json-output", "-",
            "--timeout", "5",
            "--quiet",
        ]
    }

    /// The CoreDevice error devicectl returns when the display hosts no
    /// session ("The specified display is not currently hosting a
    /// resizable app session").
    static let noSessionErrorCode = 24004

    /// Pure classification of a finished devicectl run, so every shape can
    /// be pinned without CoreDevice. devicectl always writes the JSON
    /// document — success *and* failure — so the exit status alone is not
    /// trusted; the document is.
    public static func classify(terminationStatus: Int32, stdout: Data, stderr: Data) -> ResizableAppSessionState {
        let json = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any]

        if let result = json?["result"] as? [String: Any],
           let displayUniqueID = result["displayUniqueId"] as? String, !displayUniqueID.isEmpty,
           let size = result["preferredSize"] as? [Any], size.count == 2,
           let width = Self.number(size[0]), let height = Self.number(size[1])
        {
            return .active(ResizableAppSession(
                displayUniqueID: displayUniqueID,
                displayName: (result["displayName"] as? String) ?? "Resizable",
                preferredWidth: width,
                preferredHeight: height
            ))
        }

        if let error = json?["error"] as? [String: Any] {
            let code = Self.number(error["code"]).map { Int($0) }
            if code == noSessionErrorCode {
                return .inactive
            }
            let description = ((error["userInfo"] as? [String: Any])?["NSLocalizedDescription"] as? [String: Any])?["string"] as? String
            let domain = (error["domain"] as? String) ?? "CoreDevice"
            return .unavailable(reason: "\(domain) error \(code.map(String.init) ?? "?")\(description.map { ": \($0)" } ?? "")")
        }

        let text = (String(data: stderr, encoding: .utf8) ?? "") + (String(data: stdout, encoding: .utf8) ?? "")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("unrecognized subcommand")
            || trimmed.localizedCaseInsensitiveContains("unknown subcommand")
            || trimmed.localizedCaseInsensitiveContains("unexpected argument")
        {
            return .unavailable(reason: "devicectl has no `device info appResize` subcommand (Xcode 27+ required)")
        }
        return .unavailable(reason: "devicectl exited \(terminationStatus)\(trimmed.isEmpty ? "" : ": \(trimmed.prefix(300))")")
    }

    /// Spawns devicectl and classifies the outcome. Never throws: a failing
    /// probe is `.unavailable`, and callers treat that as "no session".
    /// `executablePath` is injectable so tests can drive the drain against
    /// `/bin/sh`; production uses `xcrun`.
    public static func run(udid: String, executablePath: String = "/usr/bin/xcrun", arguments: [String]? = nil) -> ResizableAppSessionState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments ?? Self.arguments(udid: udid)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain both pipes while the child runs so neither can fill the
        // ~64 KB pipe buffer and deadlock `waitUntilExit()`. Same drain as
        // `SimctlDeviceLister.runSimctl` and `Devicectl.run`.
        let bufferLock = NSLock()
        var outBuffer = Data()
        var errBuffer = Data()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            bufferLock.lock(); outBuffer.append(chunk); bufferLock.unlock()
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            bufferLock.lock(); errBuffer.append(chunk); bufferLock.unlock()
        }

        do {
            try process.run()
        } catch {
            return .unavailable(reason: "could not spawn xcrun devicectl: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        bufferLock.lock()
        outBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
        errBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
        bufferLock.unlock()

        return classify(terminationStatus: process.terminationStatus, stdout: outBuffer, stderr: errBuffer)
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}

// MARK: - Monitor (cache)

/// Per-UDID cache in front of `ResizableAppSessionProbe`. Lives in the
/// per-UDID daemon for daemon-routed verbs, so a burst of commands pays
/// one ~0.3 s devicectl spawn per `ttl` rather than one per command.
///
/// Why a time-based cache is acceptable here: a session starting or
/// ending is a rare, user-driven event, and the cost of a stale answer
/// is bounded — at most `ttl` seconds of the pre-fix behaviour (a tap
/// reported as delivered that was not) — against a check that otherwise
/// taxes every touch verb and `ui`.
///
/// Skipped entirely (as `.unavailable`) only under
/// `SIM_USE_RESIZE_SESSION_CHECK=0`; a devicectl that lacks the subcommand
/// is remembered for the life of the process. There is deliberately no
/// "selected Xcode is older than 27" shortcut: the host's `xcode-select`
/// says nothing about a simulator another Xcode or Device Hub already put
/// into a session, and Xcode 26.6's devicectl answers the query correctly
/// (review finding R150-08).
public actor ResizableAppSessionMonitor {
    public typealias Probe = @Sendable (String) -> ResizableAppSessionState

    public static let shared = ResizableAppSessionMonitor()

    public static let defaultTTL: TimeInterval = 5
    public static let disableEnvironmentKey = "SIM_USE_RESIZE_SESSION_CHECK"

    /// In-band evidence that the frontmost scene is resized: the AX root
    /// frame's size when it is neither the device's portrait size nor its
    /// landscape swap, nor a known panel downscale (see
    /// `AccessibilityFetcher.resizedSceneEvidence`). Compared by value, so
    /// the same evidence seen again does not re-probe.
    public struct SceneEvidence: Equatable, Sendable {
        public let width: Double
        public let height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    private struct CacheEntry {
        let state: ResizableAppSessionState
        let checkedAt: Date
        /// The evidence the probe was made with — nil when none was offered.
        let evidence: SceneEvidence?
    }

    private let ttl: TimeInterval
    private let clock: @Sendable () -> Date
    private let probe: Probe
    private let environment: [String: String]
    private var cache: [String: CacheEntry] = [:]
    private var toolUnavailableReason: String?
    private(set) var probeCount = 0

    public init(
        ttl: TimeInterval = ResizableAppSessionMonitor.defaultTTL,
        clock: @escaping @Sendable () -> Date = { Date() },
        probe: @escaping Probe = { ResizableAppSessionProbe.run(udid: $0) },
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.ttl = ttl
        self.clock = clock
        self.probe = probe
        self.environment = environment
    }

    /// The session state for `udid`, from the cache when fresh.
    ///
    /// `evidence` is in-band evidence of a resized scene (see
    /// `SceneEvidence`). Evidence that *differs* from what the cached
    /// non-active answer was probed with bypasses that answer, so a
    /// session that started inside the TTL window is noticed on the first
    /// command that can see it, instead of up to `ttl` seconds later. The
    /// same evidence seen again does not re-probe: a display whose AX size
    /// legitimately never matches the device size (review finding
    /// R150-03) pays one probe per TTL like everyone else. A cached
    /// *active* answer is never bypassed: nothing in-band proves a session
    /// ended, and the TTL already bounds that staleness.
    public func state(for udid: String, evidence: SceneEvidence? = nil) -> ResizableAppSessionState {
        if let raw = environment[Self.disableEnvironmentKey]?.lowercased(),
           ["0", "false", "no", "off"].contains(raw)
        {
            return .unavailable(reason: "disabled by \(Self.disableEnvironmentKey)=\(raw)")
        }
        if let reason = toolUnavailableReason {
            return .unavailable(reason: reason)
        }

        let now = clock()
        if let entry = cache[udid], now.timeIntervalSince(entry.checkedAt) < ttl {
            if case .active = entry.state { return entry.state }
            if evidence == nil || evidence == entry.evidence { return entry.state }
        }

        probeCount += 1
        let state = probe(udid)
        if case .unavailable(let reason) = state, reason.contains("subcommand") {
            toolUnavailableReason = reason
        }
        cache[udid] = CacheEntry(state: state, checkedAt: now, evidence: evidence)
        return state
    }

    /// Drops the cached answer for `udid` so the next query re-probes.
    public func invalidate(udid: String) {
        cache[udid] = nil
    }
}

// MARK: - Guard (touch verbs)

/// Thrown instead of dispatching a touch while a session is active. Keyboard
/// HID (`type`, `key`, `key-combo`, `key-sequence`, Cmd+V `paste`) is
/// device-wide and *does* reach the resized app (verified live), so only
/// touch paths take this: the touch verbs, touch-bearing `batch` steps, and
/// `paste --via-menu` (a long-press plus menu taps).
public struct ResizableAppSessionError: LocalizedError, HintProviding, Equatable {
    public let verb: String
    public let udid: String
    public let session: ResizableAppSession

    public init(verb: String, udid: String, session: ResizableAppSession) {
        self.verb = verb
        self.udid = udid
        self.session = session
    }

    public var errorDescription: String? {
        "A resizable app session (Xcode 27 Resize Mode) is active on simulator \(udid): " +
            "the frontmost app renders on the '\(session.displayName)' display (\(session.preferredSizeDescription) points requested), " +
            "but simulator touch input reaches only the main display, so this \(verb) would report success and deliver nothing " +
            "(sim-use issue #143). No input was sent."
    }

    public var hint: String? {
        "End the session — stop the `xcrun devicectl device appResize start` process, or rotate the device — and retry, " +
            "or test at the device's native size. `ui`, `screenshot`, `type`, the key verbs and Cmd+V `paste` keep working during a session; " +
            "`paste --via-menu` is a touch path and is refused like the touch verbs. " +
            "Set \(ResizableAppSessionMonitor.disableEnvironmentKey)=0 to skip this check."
    }
}

/// Thrown instead of starting a video capture while a session is active.
/// `record-video` and `stream-video` read the main framebuffer (the only
/// one the pinned idb exposes), which shows just the wallpaper during a
/// session; unlike `screenshot` they are not redirected, because their
/// pipelines (encoder, GIF transcode, stdout sink) sit on that framebuffer
/// (review finding R150-06).
public struct ResizableAppSessionCaptureError: LocalizedError, HintProviding, Equatable {
    public let verb: String
    public let udid: String
    public let session: ResizableAppSession

    public init(verb: String, udid: String, session: ResizableAppSession) {
        self.verb = verb
        self.udid = udid
        self.session = session
    }

    public var errorDescription: String? {
        "A resizable app session (Xcode 27 Resize Mode) is active on simulator \(udid): " +
            "the frontmost app renders on the '\(session.displayName)' display (\(session.preferredSizeDescription) points requested), " +
            "but `\(verb)` captures only the main display, which shows just the wallpaper during a session, " +
            "so the output would not contain the app (sim-use issue #143). Nothing was captured."
    }

    public var hint: String? {
        "Use `screenshot`, which is redirected to the '\(session.displayName)' display automatically, or record that display with " +
            "`xcrun simctl io \(udid) recordVideo --display=\(session.displayUniqueID) <file.mov>`. " +
            "End the session — stop the `xcrun devicectl device appResize start` process, or rotate the device — to use `\(verb)` normally. " +
            "Set \(ResizableAppSessionMonitor.disableEnvironmentKey)=0 to skip this check."
    }
}

public enum ResizableAppSessionGuard {
    /// Call after global setup in every verb that dispatches touch HID.
    /// `verb` names the surface in the error ("tap", "swipe", "batch", ...).
    public static func assertTouchInputReachesApp(
        udid: String,
        verb: String,
        logger: SimUseLogger,
        monitor: ResizableAppSessionMonitor = .shared
    ) async throws {
        switch await monitor.state(for: udid) {
        case .active(let session):
            logger.info().log("Resizable app session active on \(udid) (\(session.displayName) \(session.preferredSizeDescription)); refusing \(verb)")
            throw ResizableAppSessionError(verb: verb, udid: udid, session: session)
        case .inactive:
            return
        case .unavailable(let reason):
            logger.debug().log("Resizable app session check unavailable (\(reason)); proceeding")
        }
    }

    /// Call after global setup in every verb that captures the main
    /// framebuffer without redirection (`record-video`, `stream-video`),
    /// before any output file is created or byte is emitted.
    public static func assertCaptureReachesApp(
        udid: String,
        verb: String,
        logger: SimUseLogger,
        monitor: ResizableAppSessionMonitor = .shared
    ) async throws {
        switch await monitor.state(for: udid) {
        case .active(let session):
            logger.info().log("Resizable app session active on \(udid) (\(session.displayName) \(session.preferredSizeDescription)); refusing \(verb) (main-display capture only)")
            throw ResizableAppSessionCaptureError(verb: verb, udid: udid, session: session)
        case .inactive:
            return
        case .unavailable(let reason):
            logger.debug().log("Resizable app session check unavailable (\(reason)); proceeding")
        }
    }
}

// MARK: - Advisories (read-only verbs)

public enum ResizableAppSessionAdvisory {
    /// For `describe-ui`: the tree is the app's own, but hit-test based
    /// steps were skipped because the hit-test resolves on the main display.
    public static func describeUI(
        session: ResizableAppSession,
        sceneSize: (width: Double, height: Double)?,
        native: NativePortraitSize?
    ) -> CommandAdvisory {
        var sizes = "requested \(session.preferredSizeDescription) points"
        if let sceneSize {
            sizes = "\(ResizableAppSession.format(sceneSize.width))x\(ResizableAppSession.format(sceneSize.height)) points (\(sizes))"
        }
        if let native {
            sizes += " while the device's main display is \(ResizableAppSession.format(native.width))x\(ResizableAppSession.format(native.height))"
        }
        return CommandAdvisory(
            kind: .resizableAppSession,
            message: "A resizable app session (Xcode 27 Resize Mode) is active: the app renders on the '\(session.displayName)' display at \(sizes). " +
                "The outline is the app's own tree; hit-test recovery and orientation calibration were skipped because the simulator resolves points on the main display, where SpringBoard is frontmost. " +
                "Touch paths (tap, long-press, swipe, touch, gesture, multi-touch, touch-bearing batch steps, paste --via-menu) and main-display video capture (record-video, stream-video) are refused during the session; `type`, the key verbs, Cmd+V `paste` and `screenshot` work."
        )
    }

    /// For `describe-ui --point`: the answer is whatever sits on the main
    /// display at that point (SpringBoard), not the app.
    public static func pointQuery(session: ResizableAppSession) -> CommandAdvisory {
        CommandAdvisory(
            kind: .resizableAppSession,
            message: "A resizable app session (Xcode 27 Resize Mode) is active: the app renders on the '\(session.displayName)' display, but point hit-tests resolve on the main display, so this result describes SpringBoard rather than the app. Use the full `describe-ui` outline instead."
        )
    }

    /// For `screenshot`: the capture was redirected to the Resizable display.
    public static func screenshot(session: ResizableAppSession, pixelSize: (width: Int, height: Int)?) -> CommandAdvisory {
        let pixels = pixelSize.map { ", \($0.width)x\($0.height) px" } ?? ""
        return CommandAdvisory(
            kind: .resizableAppSession,
            message: "Captured the '\(session.displayName)' display (\(session.preferredSizeDescription) points requested\(pixels)) because a resizable app session (Xcode 27 Resize Mode) is active; the main display shows only the wallpaper during a session."
        )
    }
}

// MARK: - Screenshot capture

/// Captures the Resizable display through `simctl io … screenshot
/// --display=<uuid>`. CoreSimulator accepts the CoreDevice display UUID
/// directly (also the screen name `Resizable`; both verified live) and
/// crops the surface to the app's scene — 560x874 points came back as
/// 1680x2622 px, not the 7680x4320 px display canvas CoreDevice reports.
///
/// Not routed through FBSimulatorControl because the pinned idb's
/// `FBFramebuffer.mainScreenSurface` only knows `displayClass == 0`, and
/// the IO port descriptor carries no display UUID to match against.
public enum ResizableDisplayScreenshot {
    /// Pinned by test.
    public static func arguments(udid: String, displayUniqueID: String, destination: URL) -> [String] {
        ["simctl", "io", udid, "screenshot", "--type=png", "--display=\(displayUniqueID)", destination.path]
    }

    /// Writes the PNG to `destination` and returns its pixel size when
    /// readable. `simctl` exits non-zero and writes no file for an unknown
    /// display ("Device does not have a '…' display port"), which surfaces
    /// as a `CLIError` naming the display.
    public static func capture(
        udid: String,
        session: ResizableAppSession,
        to destination: URL,
        executablePath: String = "/usr/bin/xcrun"
    ) throws -> (width: Int, height: Int)? {
        do {
            _ = try SimctlDeviceLister.runSimctl(
                executablePath: executablePath,
                args: arguments(udid: udid, displayUniqueID: session.displayUniqueID, destination: destination)
            )
        } catch {
            throw CLIError(errorDescription: "Could not capture the '\(session.displayName)' display (\(session.displayUniqueID)) of a resizable app session: \(error.localizedDescription)")
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw CLIError(errorDescription: "simctl reported success but wrote no screenshot of the '\(session.displayName)' display to \(destination.path)")
        }
        return pixelSize(of: destination)
    }

    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
