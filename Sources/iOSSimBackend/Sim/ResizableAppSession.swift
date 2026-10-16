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
/// The session moves the app off the main display, which every simulator
/// primitive used to be bound to (issue #143). This file detects the
/// session through CoreDevice; `RoutingDisplayResolver` then routes touch
/// input, hit-tests and screenshots to the `Resizable` display, and the
/// video verbs refuse until they can capture it. Evidence and routing:
/// docs/ai/009-resizable-app-session/000-investigation.md and
/// docs/ai/010-display-routing/000-plan.md.
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
        classify(DevicectlQueryOutput(terminationStatus: terminationStatus, stdout: stdout, stderr: stderr))
    }

    static func classify(_ output: DevicectlQueryOutput) -> ResizableAppSessionState {
        if let result = output.document?["result"] as? [String: Any],
           let displayUniqueID = result["displayUniqueId"] as? String, !displayUniqueID.isEmpty,
           let size = result["preferredSize"] as? [Any], size.count == 2,
           let width = DevicectlQuery.number(size[0]), let height = DevicectlQuery.number(size[1])
        {
            return .active(ResizableAppSession(
                displayUniqueID: displayUniqueID,
                displayName: (result["displayName"] as? String) ?? "Resizable",
                preferredWidth: width,
                preferredHeight: height
            ))
        }

        if let error = output.errorSummary {
            if error.code == noSessionErrorCode {
                return .inactive
            }
            return .unavailable(reason: error.summary)
        }

        if output.isUnknownSubcommand {
            return .unavailable(reason: "devicectl has no `device info appResize` subcommand (Xcode 27+ required)")
        }
        let trimmed = output.combinedText
        return .unavailable(reason: "devicectl exited \(output.terminationStatus)\(trimmed.isEmpty ? "" : ": \(trimmed.prefix(300))")")
    }

    /// Spawns devicectl and classifies the outcome. Never throws: a failing
    /// probe is `.unavailable`, and callers treat that as "no session".
    /// `executablePath` is injectable so tests can drive the drain against
    /// `/bin/sh`; production uses `xcrun`.
    public static func run(udid: String, executablePath: String = "/usr/bin/xcrun", arguments: [String]? = nil) -> ResizableAppSessionState {
        var spawnFailure = "could not spawn xcrun devicectl"
        guard let output = DevicectlQuery.run(
            arguments: arguments ?? Self.arguments(udid: udid),
            executablePath: executablePath,
            spawnError: { spawnFailure = $0 }
        ) else {
            return .unavailable(reason: spawnFailure)
        }
        return classify(output)
    }
}

// MARK: - Monitor (cache)

/// Per-UDID cache in front of `ResizableAppSessionProbe`. Lives in the
/// per-UDID daemon for daemon-routed verbs, so a burst of commands pays
/// one ~0.3 s devicectl spawn per `ttl` rather than one per command.
///
/// Why a time-based cache is acceptable here: a session starting or
/// ending is a rare, user-driven event, and the cost of a stale answer
/// is bounded — at most `ttl` seconds of touch input routed to the
/// display the app just left — against a check that otherwise taxes
/// every touch verb and `ui`. A fold or rotation invalidates it.
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
        /// The probe was made because the AX root was the device's own size.
        let deviceSizedRoot: Bool
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
    public func state(for udid: String, evidence: SceneEvidence? = nil, deviceSizedRoot: Bool = false) -> ResizableAppSessionState {
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
            if case .active = entry.state {
                // An AX root at the device's own size is evidence the session
                // ended: touch input is routed to the Resizable display while
                // the answer says active, so a stale one would tap the wrong
                // display. Re-probe once; a session that really is at the
                // device's size then rides the cache.
                if deviceSizedRoot, !entry.deviceSizedRoot {
                    probeCount += 1
                    let state = probe(udid)
                    cache[udid] = CacheEntry(state: state, checkedAt: now, evidence: evidence, deviceSizedRoot: true)
                    return state
                }
                return entry.state
            }
            if evidence == nil || evidence == entry.evidence { return entry.state }
        }

        probeCount += 1
        let state = probe(udid)
        if case .unavailable(let reason) = state, reason.contains("subcommand") {
            toolUnavailableReason = reason
        }
        cache[udid] = CacheEntry(state: state, checkedAt: now, evidence: evidence, deviceSizedRoot: deviceSizedRoot)
        return state
    }

    /// Drops the cached answer for `udid` so the next query re-probes.
    public func invalidate(udid: String) {
        cache[udid] = nil
    }
}

// MARK: - Capture refusal

/// Thrown instead of starting a video capture while a session is active.
/// `record-video` and `stream-video` read the main framebuffer (the only
/// one the pinned idb exposes), which shows just the wallpaper during a
/// session; unlike `screenshot` they are not redirected, because their
/// pipelines (encoder, GIF transcode, stdout sink) sit on that framebuffer
/// (review finding R150-06).
public struct ResizableAppSessionCaptureError: RoutingDisplayRefusal, Equatable {
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

// MARK: - Advisories (read-only verbs)

public enum ResizableAppSessionAdvisory {
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

/// Captures one display through `simctl io … screenshot --display=<uuid>`:
/// the Resize Mode `Resizable` display (issue #143) and a secondary
/// integrated display such as the unfolded iPhone Duo inner screen.
/// CoreSimulator accepts the CoreDevice display UUID directly (also the
/// display name; both verified live), crops the `Resizable` surface to the
/// app's scene — 560x874 points came back as 1680x2622 px, not the
/// 7680x4320 px canvas — and returns a secondary display already rotated
/// to the interface (2853x2007 for the Duo inner screen at `rot90`).
///
/// Not routed through FBSimulatorControl because the pinned idb's
/// `FBFramebuffer.mainScreenSurface` only knows `displayClass == 0`, and
/// the IO port descriptor carries no display UUID to match against.
public enum DisplayScreenshot {
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
        displayUniqueID: String,
        displayName: String,
        to destination: URL,
        executablePath: String = "/usr/bin/xcrun"
    ) throws -> (width: Int, height: Int)? {
        do {
            _ = try SimctlDeviceLister.runSimctl(
                executablePath: executablePath,
                args: arguments(udid: udid, displayUniqueID: displayUniqueID, destination: destination)
            )
        } catch {
            throw CLIError(errorDescription: "Could not capture the '\(displayName)' display (\(displayUniqueID)): \(error.localizedDescription)")
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw CLIError(errorDescription: "simctl reported success but wrote no screenshot of the '\(displayName)' display to \(destination.path)")
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
