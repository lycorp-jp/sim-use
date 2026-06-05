// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// High-level Android backend operations: describe-ui, devices listing,
/// `android init` bootstrap. Wraps `Adb` + `BridgeClient` and exposes a
/// surface the SimUse CLI commands consume directly.
public final class AndroidDeviceController {
    public let adb: Adb

    public init(adb: Adb = Adb()) {
        self.adb = adb
    }

    public func listDevices() throws -> [Adb.Device] {
        try adb.devices()
    }

    /// Same enumeration as `listDevices` but reshaped into the unified
    /// `Device` model that the top-level `sim-use devices` verb emits.
    /// The display name prefers `model` over `product` because that's
    /// closer to what users recognise (`Pixel 7` vs `panther`).
    ///
    /// `adb devices` already filters its output server-side, so the
    /// `onlineOnly` filter here is just a post-step convenience. We
    /// don't run a different `adb` command for it.
    public func listUnifiedDevices(onlineOnly: Bool = false) throws -> [Device] {
        let raw = try listDevices()
        let filtered = onlineOnly ? raw.filter { $0.isOnline } : raw
        return filtered.map { device in
            Device(
                udid: device.serial,
                name: device.model ?? device.product ?? device.serial,
                platform: .android,
                state: device.state,
                runtime: "Android"
            )
        }
    }

    /// Return the process-shared `BridgeClient` for `serial`.
    ///
    /// In a one-shot CLI invocation this just builds a single client
    /// and tears down with the process. Inside the `sim-use daemon`
    /// process the same instance persists across requests, keeping the
    /// auth token + adb forward + URLSession warm.
    public func bridge(serial: String) -> BridgeClient {
        BridgeClientRegistry.shared(for: serial, adb: adb)
    }

    /// End-to-end describe-ui pipeline: ensure connection, fetch tree,
    /// normalize, render, and write the outline cache.
    public func describeUI(
        serial: String,
        options: AndroidOutlineRenderer.RendererOptions = .default,
        includeRaw: Bool = true
    ) throws -> DescribeUIResult {
        let client = bridge(serial: serial)
        _ = try client.ping()

        let rawBytes = try client.fetchTreeRaw()
        let decoded = try decodeTree(rawBytes)
        guard let root = decoded.root else {
            throw BridgeError.malformedEnvelope(underlying: "Bridge returned a tree without a root element")
        }

        let outline = AndroidOutlineRenderer.render(root: root, display: decoded.display, options: options)

        // Timing-insensitive crash detection: if the system crash dialog
        // ("<app> keeps stopping") is on screen, surface it as a banner
        // above the outline (so the default text surface can't miss it)
        // plus a structured `crashDialog` field for `--json`. App-agnostic
        // and level-triggered by the current tree — no state, works
        // standalone. Independent of the daemon's process-liveness signal;
        // either alone is a sufficient crash hint.
        let crashDialog = AndroidCrashDialogDetector.detect(root: root)
        let outlineText: String
        if let crashDialog {
            outlineText = CrashDialogBanner.banner(for: crashDialog) + "\n" + outline.text
        } else {
            outlineText = outline.text
        }

        // Parsing the wire bytes into a `JSONValue` is ~30 ms on a
        // 200 KB tree, and encoding it across the daemon socket is
        // another ~80 ms. Only pay that cost when the caller has asked
        // for `--json` output (the only consumer of `raw`).
        let rawJSON: JSONValue? = includeRaw ? try JSONValue.decode(from: rawBytes) : nil

        do {
            try OutlineCache.write(outline: outline, udid: serial)
        } catch {
            // Best-effort: a cache write failure is non-fatal, but
            // log to stderr so a permissions / full-disk regression
            // is debuggable. iOS describe-ui uses the same shape
            // via `SimUseLogger`; we don't have a logger here yet,
            // so write directly to standardError.
            FileHandle.standardError.write(
                Data("warning: failed to write outline cache for \(serial): \(error.localizedDescription)\n".utf8)
            )
        }

        return DescribeUIResult(
            platform: .android,
            raw: rawJSON,
            outline: outlineText,
            entries: outline.entries,
            lists: outline.lists,
            screen: outline.screen,
            appLabel: outline.appLabel,
            appPackage: root.package,
            crashDialog: crashDialog
        )
    }

    // MARK: - Init / bootstrap

    public struct InitOptions: Sendable {
        public var apkPath: String?
        public var packageName: String
        public var serviceClass: String
        public init(
            apkPath: String? = nil,
            packageName: String = BridgeClient.bridgePackageName,
            serviceClass: String = "com.linecorp.simuse.devicebridge.service.SimuseAccessibilityService"
        ) {
            self.apkPath = apkPath
            self.packageName = packageName
            self.serviceClass = serviceClass
        }
    }

    public struct InitReport: Sendable {
        public let serial: String
        public let bridgeVersion: String
        public let protocolVersion: Int
        public let authTokenInstalled: Bool
        public let portForward: Int
    }

    /// Runs the 6-step bootstrap from `ai-doc/ANDROID_WIRE_SPEC.md`.
    /// Idempotent: rerunning on an initialized device is a no-op for
    /// every step except APK install (`install -r`).
    public func initialize(serial: String, options: InitOptions = InitOptions()) throws -> InitReport {
        // Step 1: install (or reinstall) APK.
        let apkPath = try options.apkPath ?? Self.bundledAPKPath()
        guard FileManager.default.fileExists(atPath: apkPath) else {
            throw BridgeError.transport(underlying: "Bridge APK not found at \(apkPath). Build it first via `bridge/` Gradle, or pass --apk-path.", serial: nil)
        }
        _ = try adb.install(serial: serial, apkPath: apkPath, reinstall: true, grantPermissions: true)

        // Steps 2+3: register the a11y service and enable a11y globally,
        // then poll until the settings stick. AccessibilityManagerService
        // rescans installed services asynchronously after `pm install`;
        // writes made during that window reference a component AMS does
        // not yet know about, and AMS reverts them — taking
        // `accessibility_enabled` back to 0 along with the service list.
        // Without polling, the first `init` on a real device loses the
        // race and surfaces as an opaque "network connection was lost"
        // at step 6.
        try waitForAccessibilityRegistration(
            serial: serial,
            component: "\(options.packageName)/\(options.serviceClass)",
            timeout: Self.accessibilityRegistrationTimeout
        )

        // Step 4: toggle the in-process HTTP server.
        try AuthTokenFetcher.toggleSocketServer(adb: adb, serial: serial, enabled: true)

        // Step 5: fetch the auth token.
        let token = try AuthTokenFetcher.fetch(adb: adb, serial: serial)
        let tokenOK = !token.isEmpty

        // Step 6: port-forward and ping for protocol_version check.
        let client = BridgeClient(adb: adb, serial: serial)
        let ping = try client.ping()

        return InitReport(
            serial: serial,
            bridgeVersion: ping.bridgeVersion,
            protocolVersion: ping.protocolVersion,
            authTokenInstalled: tokenOK,
            portForward: BridgeClient.defaultRemotePort
        )
    }

    /// How long `initialize` will poll for the a11y settings to stick
    /// before giving up. Real devices typically settle in under a
    /// second; we cap at 10s so a permanent block (e.g. Android 13+
    /// Restricted Settings) surfaces an actionable error instead of
    /// hanging the user.
    static let accessibilityRegistrationTimeout: TimeInterval = 10

    /// Write the a11y settings and read them back in a loop until they
    /// match the requested values, or the deadline is hit. Each
    /// iteration is ~4 adb shell roundtrips; on emulators it lands on
    /// the first try, on a slow real device 2–3 tries (~500–750 ms).
    private func waitForAccessibilityRegistration(
        serial: String,
        component: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.25
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastObserved = "uninitialized"
        repeat {
            _ = try adb.shell(serial: serial, args: [
                "settings", "put", "secure", "enabled_accessibility_services", component,
            ])
            _ = try adb.shell(serial: serial, args: [
                "settings", "put", "secure", "accessibility_enabled", "1",
            ])
            let services = try adb.shell(serial: serial, args: [
                "settings", "get", "secure", "enabled_accessibility_services",
            ]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let enabled = try adb.shell(serial: serial, args: [
                "settings", "get", "secure", "accessibility_enabled",
            ]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if services.contains(component) && enabled == "1" {
                return
            }
            lastObserved = "enabled_accessibility_services=\(services), accessibility_enabled=\(enabled)"
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        throw BridgeError.transport(underlying: """
            AccessibilityService registration never stuck after \(Int(timeout))s of polling. \
            Last observed: \(lastObserved). \
            This usually means Android's Restricted Settings is blocking ADB-installed apps \
            from being granted accessibility. Enable it manually under \
            Settings → Accessibility → sim-use device bridge, then re-run `sim-use android init`.
            """, serial: nil)
    }

    public static func bundledAPKPath() throws -> String {
        guard let url = Bundle.module.url(
            forResource: "sim-use-device-bridge",
            withExtension: "apk",
            subdirectory: "Resources"
        ) else {
            throw BridgeError.transport(underlying: "Bridge APK not found in module bundle. Build it locally via `scripts/build-bridge.sh` (requires Android SDK + JDK 17+).", serial: nil)
        }
        return url.path
    }

    // MARK: - Tree decoding

    private func decodeTree(_ data: Data) throws -> (root: ElementNode?, display: DisplayMetrics?) {
        let envelope = try JSONDecoder().decode(BridgeEnvelope<ElementNode>.self, from: data)
        if !envelope.isSuccess {
            throw BridgeError.applicationError(status: envelope.status, code: envelope.code, message: envelope.error)
        }
        return (envelope.result, envelope.display)
    }
}