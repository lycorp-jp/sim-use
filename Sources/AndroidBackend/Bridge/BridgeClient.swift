// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(FoundationNetworking)
// URLSession / URLRequest / HTTPURLResponse live in a separate module in
// swift-corelibs-foundation; on Apple platforms this import does not exist.
import FoundationNetworking
#endif
import SimUseCore

/// HTTP client that speaks the bridge wire protocol served by the
/// bridge's `server/ActionRouter.kt` ((method, path) dispatch + auth)
/// and its `handler/` classes.
///
/// Lifecycle: a client is created with a known device serial; it lazily
/// establishes an `adb forward` and fetches the auth token on first
/// request and checks provider discovery before each external HTTP operation.
/// A request lock keeps validation, endpoint replacement and sending together.
///
/// The expected bridge protocol_version is compiled in; mismatches
/// surface as `BridgeError.protocolMismatch` on the first `ping`.
///
/// Thread-safety: `BridgeClientRegistry` hands the same instance to
/// concurrent callers across daemon worker threads. The mutable cached
/// state (`cachedLocalPort`, `cachedAuthToken`, `cachedDisplay`,
/// `verifiedProtocolVersion`) is guarded by `lock: NSRecursiveLock`; every read
/// and write goes through `lock.lock() / lock.unlock()`. The
/// conformance is `@unchecked Sendable` because the synthesised one
/// would balk at the `var` properties even though they're never read
/// outside the lock.
public final class BridgeClient: @unchecked Sendable {
    public static let expectedProtocolVersion = 2
    public static let defaultRemotePort = 8080
    private var cachedRemotePort = BridgeClient.defaultRemotePort

    /// Android package id of the device-bridge APK. Single source of
    /// truth shared with `AndroidDeviceController.InitOptions`; used by
    /// the post-failure probe in `sendRaw` to tell a never-bootstrapped
    /// device apart from a mid-session connection drop.
    public static let bridgePackageName = "com.linecorp.simuse.devicebridge"

    /// Normalised CLI release version (e.g. `"0.6.0"`, no leading
    /// `v`). Set once at CLI bootstrap from the auto-generated
    /// `VERSION` constant, but only when that constant parses as a
    /// clean release tag — dev builds (`v0.5.1-130-g...-dirty`) leave
    /// this nil so day-to-day developer workflows never trip the
    /// runtime version check.
    ///
    /// When set, `ping()` compares it against the bridge APK's
    /// `versionName` and raises `BridgeError.bridgeVersionMismatch`
    /// on drift. `SIM_USE_SKIP_BRIDGE_VERSION_CHECK=1` opts out at
    /// runtime for the rare case where mismatched versions are
    /// expected (e.g. testing a CLI built locally against a previously
    /// installed APK).
    public static var expectedBridgeVersion: String?

    public let adb: Adb
    public let serial: String
    public let urlSession: URLSession
    public let connectionTimeout: TimeInterval
    public let readTimeout: TimeInterval

    /// Adb server + bridge host this client's traffic goes to.
    public let connection: BridgeConnection
    private let sessionHome: URL

    // Serialize discovery through transmission, including nested handshakes.
    private let lock = NSRecursiveLock()
    private var requestDepth = 0
    private var cachedLocalPort: Int?
    private var cachedAuthToken: String?
    private var verifiedProtocolVersion: Bool = false
    private var cachedDisplay: DisplayMetrics?

    public init(
        adb: Adb,
        serial: String,
        urlSession: URLSession? = nil,
        connectionTimeout: TimeInterval = 5,
        readTimeout: TimeInterval = 15,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sessionHome: URL = BridgeSessionStore.homeDirectory
    ) {
        self.adb = adb
        self.serial = serial
        self.connection = BridgeConnection(environment: environment)
        self.sessionHome = sessionHome
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = readTimeout
        config.timeoutIntervalForResource = readTimeout
        // No connection reuse in practice: the bridge answers every
        // request with `Connection: close` (HttpServer.kt), so each
        // call pays a fresh loopback connect — cheap through
        // `adb forward`. The cap only bounds concurrent sockets should
        // the server ever gain keep-alive.
        config.httpMaximumConnectionsPerHost = 4
        self.urlSession = urlSession ?? URLSession(configuration: config)
        self.connectionTimeout = connectionTimeout
        self.readTimeout = readTimeout

        // Restore only sessions from this connection. Before any HTTP, confirm
        // the provider's current device port and the adb forward registration.
        // A host-only change can clean up the old forward on the same server.
        if let cached = BridgeSessionStore.read(udid: serial, home: sessionHome) {
            if cached.connection == connection.identity {
                self.cachedRemotePort = cached.remotePort
                self.cachedAuthToken = cached.token
                self.cachedLocalPort = cached.localPort
            } else if cached.adbServer == connection.adbServer {
                if let forwards = try? adb.forwards() {
                    if forwards.contains(Adb.Forward(serial: serial, localPort: cached.localPort, remote: "tcp:\(cached.remotePort)")) {
                        _ = try? adb.forwardRemove(serial: serial, localPort: cached.localPort)
                    }
                    BridgeSessionStore.invalidate(udid: serial, home: sessionHome)
                }
            }
        }
    }

    // MARK: - Public entry points

    public func ping(force: Bool = false) throws -> PingResult {
        try withFreshEndpoint { try pingVerified(force: force) }
    }

    private func pingVerified(force: Bool) throws -> PingResult {
        // Provider discovery precedes this fast path on every external call.
        // Reuse the protocol check only while the endpoint remains unchanged.
        lock.lock()
        let alreadyVerified = verifiedProtocolVersion
        lock.unlock()
        if alreadyVerified && !force {
            return PingResult(result: "pong", protocolVersion: Self.expectedProtocolVersion, bridgeVersion: "")
        }

        for attempt in 0...1 {
            do {
                return try performPing(finalAttempt: attempt == 1)
            } catch {
                switch error {
                case BridgeError.httpStatus, BridgeError.malformedEnvelope,
                     BridgeError.applicationError, BridgeError.transport:
                    try cleanupEndpoint(preserving: error)
                    if attempt == 0 { continue }
                default:
                    break
                }
                throw error
            }
        }
        preconditionFailure("Handshake attempts exhausted")
    }

    private func performPing(finalAttempt: Bool) throws -> PingResult {
        let request = buildRequest(method: "GET", path: "/ping", requiresAuth: false, body: nil, contentType: nil)
        let data = try sendRaw(request: request, expectAuth: false, allowReconnect: false, classifyPingFailure: finalAttempt)
        // `/ping` is the one endpoint whose envelope is **flat**: the
        // `protocol_version` and `bridge_version` fields sit beside
        // `status` / `result`, not nested. PingResult decodes that shape
        // directly (see wire spec §GET /ping).
        let result: PingResult
        do {
            result = try JSONDecoder().decode(PingResult.self, from: data)
        } catch {
            throw BridgeError.malformedEnvelope(underlying: error.localizedDescription)
        }
        guard result.result == "pong" else {
            throw BridgeError.malformedEnvelope(underlying: "Bridge ping did not return pong")
        }
        guard result.protocolVersion == Self.expectedProtocolVersion else {
            throw BridgeError.protocolMismatch(client: Self.expectedProtocolVersion, bridge: result.protocolVersion)
        }
        // Release-version check fires only when (a) the CLI bootstrap
        // installed a normalised version (i.e. this binary was built
        // from a clean release tag, not a dev branch) and (b) the
        // operator hasn't explicitly opted out. Compared as plain
        // strings — both sides are already normalised (CLI strips the
        // leading `v`, bridge stores the raw gradle `versionName`).
        if let expectedBridge = Self.expectedBridgeVersion,
           ProcessInfo.processInfo.environment["SIM_USE_SKIP_BRIDGE_VERSION_CHECK"] != "1",
           expectedBridge != result.bridgeVersion {
            throw BridgeError.bridgeVersionMismatch(
                cli: expectedBridge,
                bridge: result.bridgeVersion,
                udid: serial
            )
        }
        lock.lock(); verifiedProtocolVersion = true; lock.unlock()
        return result
    }

    /// `GET /a11y_tree_full` → wire envelope with an `ElementNode` payload.
    public func fetchTreeRaw(filter: Bool = false) throws -> Data {
        let path = filter ? "/a11y_tree_full?filter=true" : "/a11y_tree_full"
        let request = buildRequest(method: "GET", path: path, requiresAuth: true, body: nil, contentType: nil)
        let data = try sendRaw(request: request, expectAuth: true)
        return data
    }

    /// Screen dimensions cached for the current endpoint. Keep response parsing
    /// and cache publication in the same lifecycle as discovery and transport.
    public func displayInfo() throws -> DisplayMetrics {
        try withFreshEndpoint {
            if let cached = cachedDisplay { return cached }
            let bytes = try fetchTreeRaw(filter: true)
            let envelope: BridgeEnvelope<JSONValue>
            do {
                envelope = try JSONDecoder().decode(BridgeEnvelope<JSONValue>.self, from: bytes)
            } catch {
                throw BridgeError.malformedEnvelope(underlying: error.localizedDescription)
            }
            guard let display = envelope.display else {
                throw BridgeError.malformedEnvelope(underlying: "Bridge tree response missing `display` field")
            }
            cachedDisplay = display
            return display
        }
    }

    /// `POST /tap` with form-encoded `x=…&y=…`. Coordinates in pixels.
    public func tap(x: Int, y: Int) throws {
        let body = "x=\(x)&y=\(y)".data(using: .utf8)!
        try sendNoResult(method: "POST", path: "/tap", body: body, contentType: "application/x-www-form-urlencoded")
    }

    /// `POST /swipe`.
    public func swipe(startX: Int, startY: Int, endX: Int, endY: Int, durationMs: Int) throws {
        let body = "startX=\(startX)&startY=\(startY)&endX=\(endX)&endY=\(endY)&duration=\(durationMs)".data(using: .utf8)!
        try sendNoResult(method: "POST", path: "/swipe", body: body, contentType: "application/x-www-form-urlencoded")
    }

    /// `POST /gesture` — multi-stroke gesture dispatched in parallel
    /// via `AccessibilityService.dispatchGesture`. Each stroke is
    /// either a straight line (linear endpoints) or a polyline (a list
    /// of (x, y) waypoints the bridge renders as a multi-segment
    /// `Path` and walks linearly over `duration`).
    ///
    /// The polyline shape carries arc / curved gestures (rotate
    /// presets) from the Swift verb layer to the Android side without
    /// extending the bridge with arc-specific parameters: the Swift
    /// side samples the arc into ~N waypoints, the bridge plays them
    /// back as a single curved stroke.
    public func gesture(strokes: [BridgeStroke]) throws {
        let payload = BridgeGesturePayload(strokes: strokes)
        let body = try JSONEncoder().encode(payload)
        try sendNoResult(method: "POST", path: "/gesture", body: body, contentType: "application/json")
    }

    /// `POST /keyboard/input`. Text is base64-encoded UTF-8.
    public func inputText(_ text: String, clear: Bool = true) throws {
        let b64 = Self.formSafeBase64(Data(text.utf8))
        let body = "base64_text=\(b64)&clear=\(clear)".data(using: .utf8)!
        try sendNoResult(method: "POST", path: "/keyboard/input", body: body, contentType: "application/x-www-form-urlencoded")
    }

    /// `POST /keyboard/key`. Accepts only HOME (3), BACK (4), RECENTS (187).
    public func pressKey(_ keyCode: Int) throws {
        let body = "key_code=\(keyCode)".data(using: .utf8)!
        try sendNoResult(method: "POST", path: "/keyboard/key", body: body, contentType: "application/x-www-form-urlencoded")
    }

    /// `GET /keyboard/state` → soft-keyboard visibility + active IME
    /// package (when discoverable). Requires bridge protocol_version ≥ 1
    /// with `flagRetrieveInteractiveWindows` in the accessibility service
    /// config; older bridges return 404 here.
    public func keyboardState() throws -> KeyboardStateResult {
        let request = buildRequest(method: "GET", path: "/keyboard/state", requiresAuth: true, body: nil, contentType: nil)
        let envelope: BridgeEnvelope<KeyboardStateResult> = try send(request: request, expectAuth: true)
        guard envelope.isSuccess, let result = envelope.result else {
            throw BridgeError.applicationError(status: envelope.status, code: envelope.code, message: envelope.error)
        }
        return result
    }

    /// `POST /paste`. Sets the device clipboard and triggers `ACTION_PASTE`
    /// on the currently focused field. `replace=true` selects the field's
    /// existing content before pasting so the paste overwrites rather than
    /// inserts at the caret. Requires bridge protocol_version ≥ 1; older
    /// bridges return 404 here.
    public func paste(_ text: String, replace: Bool = false) throws {
        let b64 = Self.formSafeBase64(Data(text.utf8))
        let body = "base64_text=\(b64)&replace=\(replace)".data(using: .utf8)!
        try sendNoResult(method: "POST", path: "/paste", body: body, contentType: "application/x-www-form-urlencoded")
    }

    /// Standard base64 of `data`, with every character that has reserved
    /// meaning in `application/x-www-form-urlencoded` percent-encoded:
    /// `+` (which the form decoder turns into a space), `/` (URI-
    /// reserved), and `=` (the form parser's key/value separator).
    ///
    /// `=` works today in value position because
    /// `HttpServer.parseFormUrlEncoded` on the bridge side splits on
    /// the *first* `=` per pair, but escaping it here removes a
    /// silent failure mode the day someone swaps the parser for
    /// e.g. `URI.getRawQuery` / a stricter library. The Kotlin side
    /// runs the value through `URLDecoder.decode`, so `%3D` round-
    /// trips back to literal `=` on the receive side regardless.
    ///
    /// Without this, any UTF-8 payload whose base64 happens to contain
    /// `+` arrives at the bridge with spaces where pluses should be
    /// and the bridge returns `{"code":"invalid_base64"}`. Roughly
    /// 1-in-25 base64 characters, so multi-byte text (CJK, emoji)
    /// trips it almost every time.
    static func formSafeBase64(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "/", with: "%2F")
            .replacingOccurrences(of: "=", with: "%3D")
    }

    /// `GET /screenshot` → base64-encoded PNG (decoded for the caller).
    public func screenshot() throws -> Data {
        let request = buildRequest(method: "GET", path: "/screenshot", requiresAuth: true, body: nil, contentType: nil)
        let envelope: BridgeEnvelope<String> = try send(request: request, expectAuth: true)
        guard envelope.isSuccess, let b64 = envelope.result else {
            throw BridgeError.applicationError(status: envelope.status, code: envelope.code, message: envelope.error)
        }
        // `.ignoreUnknownCharacters` so a future bridge that wraps the
        // base64 output (line-folded MIME shape, `NO_WRAP`-not-set, etc.)
        // doesn't break clients. Strict mode rejects any embedded
        // newline.
        guard let data = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]) else {
            throw BridgeError.malformedEnvelope(underlying: "screenshot result was not valid base64")
        }
        return data
    }

    /// Forget the endpoint, removing its forward only after checking ownership.
    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        try? replaceEndpoint(with: nil)
    }

    // MARK: - Internal

    private func withFreshEndpoint<Result>(_ body: () throws -> Result) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        if requestDepth == 0 {
            let endpoint = try AuthTokenFetcher.fetchEndpoint(adb: adb, serial: serial)
            try replaceEndpoint(with: endpoint)
        }
        requestDepth += 1
        defer { requestDepth -= 1 }
        return try body()
    }

    /// Called under the recursive request lock. Discovery, cache replacement
    /// and request transmission form one serialized lifecycle.
    private func replaceEndpoint(with endpoint: AuthTokenFetcher.Endpoint?) throws {
        if let port = cachedLocalPort {
            // A failed list preserves the entire unconfirmed session. A local
            // port number alone is insufficient evidence to remove a forward.
            let owned = try adb.forwards().contains(Adb.Forward(
                serial: serial, localPort: port, remote: "tcp:\(cachedRemotePort)"
            ))
            if !owned || endpoint?.remotePort != cachedRemotePort {
                if owned { try adb.forwardRemove(serial: serial, localPort: port) }
                cachedLocalPort = nil
                verifiedProtocolVersion = false
                cachedDisplay = nil
                BridgeSessionStore.invalidate(udid: serial, home: sessionHome)
            }
        }
        if cachedAuthToken != endpoint?.token {
            verifiedProtocolVersion = false
            cachedDisplay = nil
        }
        cachedAuthToken = endpoint?.token
        cachedRemotePort = endpoint?.remotePort ?? Self.defaultRemotePort
        if endpoint == nil {
            verifiedProtocolVersion = false
            cachedDisplay = nil
            BridgeSessionStore.invalidate(udid: serial, home: sessionHome)
        } else {
            persistSession()
        }
    }

    /// Cleanup must not hide the failure that triggered recovery. If ownership
    /// cannot be checked, retain the endpoint and stop with the original failure.
    private func cleanupEndpoint(preserving failure: Error) throws {
        do {
            try replaceEndpoint(with: nil)
        } catch {
            FileHandle.standardError.write(Data("Bridge endpoint cleanup failed; preserving the original request error.\n".utf8))
            throw failure
        }
    }

    private func currentLocalPort() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let port = cachedLocalPort { return port }
        _ = try currentAuthToken()
        let port = try adb.forward(serial: serial, remotePort: cachedRemotePort)
        cachedLocalPort = port
        persistSession()
        return port
    }

    private func currentAuthToken() throws -> String {
        lock.lock()
        if let token = cachedAuthToken {
            lock.unlock()
            return token
        }
        lock.unlock()

        let endpoint = try AuthTokenFetcher.fetchEndpoint(adb: adb, serial: serial)
        let token = endpoint.token
        lock.lock()
        cachedAuthToken = token
        cachedRemotePort = endpoint.remotePort
        lock.unlock()
        persistSession()
        return token
    }

    private func persistSession() {
        lock.lock()
        let token = cachedAuthToken
        let port = cachedLocalPort
        let remotePort = cachedRemotePort
        lock.unlock()
        guard let token, let port else { return }
        let session = BridgeSession(
            token: token,
            localPort: port,
            remotePort: remotePort,
            connection: connection.identity,
            adbServer: connection.adbServer
        )
        BridgeSessionStore.write(session, udid: serial, home: sessionHome)
    }

    private struct Request {
        let method: String
        let path: String
        let requiresAuth: Bool
        let body: Data?
        let contentType: String?
    }

    private func buildRequest(
        method: String,
        path: String,
        requiresAuth: Bool,
        body: Data?,
        contentType: String?
    ) -> Request {
        Request(method: method, path: path, requiresAuth: requiresAuth, body: body, contentType: contentType)
    }

    /// Materialize the URL and bearer only inside a validated request lifecycle.
    private func makeURLRequest(from request: Request) throws -> URLRequest {
        let port = try currentLocalPort()
        guard let url = URL(string: "http://\(connection.bridgeHost):\(port)\(request.path)") else {
            throw BridgeError.transport(underlying: "Could not build URL for \(request.path)", serial: serial)
        }
        var req = URLRequest(url: url)
        req.httpMethod = request.method
        req.timeoutInterval = readTimeout
        if let body = request.body {
            req.httpBody = body
            if let contentType = request.contentType {
                req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        }
        if request.requiresAuth {
            let token = try currentAuthToken()
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func sendRaw(
        request: Request,
        expectAuth: Bool,
        allowReconnect: Bool = true,
        classifyPingFailure: Bool = false
    ) throws -> Data {
        try withFreshEndpoint {
            let current = try makeURLRequest(from: request)
            return try sendVerified(
                request: current, expectAuth: expectAuth,
                allowReconnect: allowReconnect, classifyPingFailure: classifyPingFailure
            )
        }
    }

    private func sendVerified(
        request: URLRequest,
        expectAuth: Bool,
        allowReconnect: Bool,
        classifyPingFailure: Bool
    ) throws -> Data {
        // Eager handshake on the first non-ping HTTP call: run `ping()`
        // once so `BridgeError.protocolMismatch` and
        // `BridgeError.bridgeVersionMismatch` surface before the verb's
        // own response comes back. Without this, only verbs that
        // explicitly call `ping()` (today: `describe-ui` and the
        // `ping` verb itself) would trigger the version check, and a
        // user who only runs `sim-use tap` against a mismatched APK
        // would never see a warning.
        //
        // Path-based recursion guard: `ping()` builds a `/ping` URL
        // and re-enters `sendRaw`; that re-entry skips this branch and
        // proceeds straight to the wire. Once `ping()` succeeds and
        // flips `verifiedProtocolVersion`, every subsequent sendRaw
        // reuses that protocol check after the outer provider validation.
        var request = request
        lock.lock()
        let alreadyVerified = verifiedProtocolVersion
        lock.unlock()
        if !alreadyVerified, request.url?.path != "/ping" {
            _ = try ping()
            // The handshake can replace the forward and token.
            request = try makeURLRequest(from: rebuildRequest(from: request, expectAuth: expectAuth))
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try urlSession.synchronousDataTask(with: request)
        } catch {
            let definitelyNotSent = (error as? URLError)?.code == .cannotConnectToHost
            if allowReconnect && (request.httpMethod == "GET" || definitelyNotSent) {
                // adb forward died or the bridge restarted. Drop caches and
                // try once more — the port forward will be re-created, the
                // token re-fetched.
                lock.lock()
                let wasVerified = verifiedProtocolVersion
                lock.unlock()
                let failure = BridgeError.transport(underlying: error.localizedDescription, serial: serial)
                try cleanupEndpoint(preserving: failure)
                // If we'd previously verified the protocol_version in this
                // process, the bridge we're reconnecting to might be a
                // different build (e.g. someone reinstalled the APK between
                // requests against a long-running daemon). Re-ping so a
                // mismatch surfaces as `BridgeError.protocolMismatch`
                // instead of being served silently by the new bridge.
                // Bounded recursion: endpoint replacement already cleared
                // `verifiedProtocolVersion`, so the ping's own
                // transport-error retry will not loop back into this
                // branch.
                if wasVerified {
                    _ = try ping(force: true)
                }
                if cachedAuthToken == nil {
                    let endpoint = try AuthTokenFetcher.fetchEndpoint(adb: adb, serial: serial)
                    try replaceEndpoint(with: endpoint)
                }
                let retry = rebuildRequest(from: request, expectAuth: expectAuth)
                return try sendRaw(request: retry, expectAuth: expectAuth, allowReconnect: false)
            }
            if request.url?.path == "/ping" {
                let failure = classifyPingFailure
                    ? connectionFailure(underlying: error)
                    : BridgeError.transport(underlying: error.localizedDescription, serial: serial)
                try cleanupEndpoint(preserving: failure)
                throw failure
            }
            // A GET has exhausted reconnect, or a POST may already have
            // executed. Report the failure and discard the endpoint without
            // replaying an action whose outcome is unknown.
            let failure = connectionFailure(underlying: error)
            try cleanupEndpoint(preserving: failure)
            throw failure
        }
        guard let http = response as? HTTPURLResponse else {
            throw BridgeError.transport(underlying: "Non-HTTP response from bridge", serial: serial)
        }
        switch http.statusCode {
        case 200:
            return data
        case 401:
            if allowReconnect && expectAuth {
                let failure = BridgeError.httpStatus(code: 401, body: String(data: data, encoding: .utf8) ?? "")
                try cleanupEndpoint(preserving: failure)
                if cachedAuthToken == nil {
                    let endpoint = try AuthTokenFetcher.fetchEndpoint(adb: adb, serial: serial)
                    try replaceEndpoint(with: endpoint)
                }
                let retry = rebuildRequest(from: request, expectAuth: expectAuth)
                return try sendRaw(request: retry, expectAuth: expectAuth, allowReconnect: false)
            }
            throw BridgeError.httpStatus(code: 401, body: String(data: data, encoding: .utf8) ?? "")
        default:
            // Try to decode the bridge's structured error envelope first
            // (`{"status":"error","code":"...","error":"..."}`) so callers
            // see a typed `.applicationError` with the machine-readable
            // `code` field intact. Fall back to `.httpStatus` only when
            // the body isn't the expected JSON shape (proxy errors, raw
            // HTML, etc.).
            struct Empty: Decodable {}
            if let envelope = try? JSONDecoder().decode(BridgeEnvelope<Empty>.self, from: data),
               !envelope.isSuccess {
                throw BridgeError.applicationError(
                    status: envelope.status,
                    code: envelope.code,
                    message: envelope.error
                )
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BridgeError.httpStatus(code: http.statusCode, body: body)
        }
    }

    /// Map a connection-level URLSession failure to the most actionable
    /// `BridgeError`. Used after reconnect fails or an action cannot safely
    /// be replayed. A single `pm list packages` probe checks whether the
    /// bridge APK is installed. If it is absent — a common reason that a
    /// first call returns "network connection was lost" —
    /// surface `.bridgeNotInstalled`, whose message already names the
    /// exact `sim-use android init --device <serial>` to run. Otherwise
    /// keep the raw transport error, now tagged with `serial` so
    /// `BridgeError.hint` can still nudge toward re-init for the
    /// installed-but-not-bootstrapped cases (a11y off, server off).
    /// `internal` (not `private`) so `BridgeClientConnectionFailureTests`
    /// can drive the mapping with a script-backed `Adb` instead of a
    /// live socket.
    func connectionFailure(underlying: Error) -> BridgeError {
        if isBridgeInstalled() == false {
            return .bridgeNotInstalled(serial: serial)
        }
        return .transport(underlying: underlying.localizedDescription, serial: serial)
    }

    /// `true` / `false` when the probe runs cleanly; `nil` when adb
    /// itself errored (device vanished mid-probe, etc.) — callers treat
    /// `nil` as "don't know", falling back to the raw transport error
    /// rather than risk a misleading "not installed" claim.
    func isBridgeInstalled() -> Bool? {
        guard let result = try? adb.shell(
            serial: serial,
            args: ["pm", "list", "packages", Self.bridgePackageName]
        ) else { return nil }
        return result.stdout.contains(Self.bridgePackageName)
    }

    private func send<R: Decodable>(request: Request, expectAuth: Bool) throws -> BridgeEnvelope<R> {
        let data = try sendRaw(request: request, expectAuth: expectAuth)
        do {
            return try JSONDecoder().decode(BridgeEnvelope<R>.self, from: data)
        } catch {
            throw BridgeError.malformedEnvelope(underlying: error.localizedDescription)
        }
    }

    private func sendNoResult(method: String, path: String, body: Data?, contentType: String?) throws {
        let request = buildRequest(method: method, path: path, requiresAuth: true, body: body, contentType: contentType)
        struct Empty: Decodable {}
        let envelope: BridgeEnvelope<Empty> = try send(request: request, expectAuth: true)
        if !envelope.isSuccess {
            throw BridgeError.applicationError(status: envelope.status, code: envelope.code, message: envelope.error)
        }
    }

    private func rebuildRequest(from old: URLRequest, expectAuth: Bool) -> Request {
        let path = old.url.flatMap { url -> String in
            var pathPart = url.path
            if let q = url.query, !q.isEmpty { pathPart += "?\(q)" }
            return pathPart
        } ?? "/"
        return buildRequest(
            method: old.httpMethod ?? "GET",
            path: path,
            requiresAuth: expectAuth,
            body: old.httpBody,
            contentType: old.value(forHTTPHeaderField: "Content-Type")
        )
    }
}

// MARK: - URLSession sync helper

private extension URLSession {
    func synchronousDataTask(with request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?
        let task = dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        if let error = resultError {
            throw error
        }
        guard let data = resultData, let response = resultResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}