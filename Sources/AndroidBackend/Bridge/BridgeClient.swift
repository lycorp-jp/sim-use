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
/// request, then discovers again only after failure. A disk session needs an
/// adb ownership check before its first HTTP, and provider discovery too
/// unless a discovery created it within `restoredSessionTrustWindow`.
///
/// The expected bridge protocol_version is compiled in; mismatches
/// surface as `BridgeError.protocolMismatch` on the first `ping`.
///
/// Thread-safety: `BridgeClientRegistry` hands the same instance to
/// concurrent callers across daemon worker threads. The mutable cached
/// state is guarded by `lock`. HTTP uses immutable session snapshots outside
/// the lock. Session generations prevent old responses and failures from
/// changing a newer connection. A per-device file lock coordinates disk and
/// forward transitions across clients. See docs/ai/012-android-bridge-discovery/.
public final class BridgeClient: @unchecked Sendable {
    public static let expectedProtocolVersion = 2
    public static let defaultRemotePort = 8080

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

    private let lock = NSLock()
    private struct Session {
        let generation: UInt64
        let token: String
        let localPort: Int
        let remotePort: Int
    }
    private var generation: UInt64 = 0
    private var session: Session?
    private var verifiedPing: PingResult?
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
    }

    // MARK: - Public entry points

    public func ping(force: Bool = false) throws -> PingResult {
        try verifiedEndpoint(force: force).ping
    }

    /// Connect after `init` started the bridge. A restart can move the
    /// bridge to another port, so a recent disk session is not sufficient:
    /// discover again, and poll up to `startupTimeout` for the listener.
    public func connectAfterBridgeStart(startupTimeout: TimeInterval) throws -> (ping: PingResult, remotePort: Int) {
        do {
            lock.lock()
            defer { lock.unlock() }
            session = nil
            verifiedPing = nil
            cachedDisplay = nil
            _ = try establishEndpoint(startupTimeout: startupTimeout)
        }
        let verified = try verifiedEndpoint()
        return (verified.ping, verified.session.remotePort)
    }

    private func verifiedEndpoint(force: Bool = false) throws -> (session: Session, ping: PingResult) {
        for attempt in 0...1 {
            let endpoint = try currentEndpoint()
            lock.lock()
            let cached = session?.generation == endpoint.generation ? verifiedPing : nil
            lock.unlock()
            if let cached, !force { return (endpoint, cached) }
            do {
                let result = try performPing(endpoint: endpoint, finalAttempt: attempt == 1)
                lock.lock()
                let isCurrent = session?.generation == endpoint.generation
                if isCurrent { verifiedPing = result }
                lock.unlock()
                if isCurrent { return (endpoint, result) }
                if attempt == 0 { continue }
                throw BridgeError.transport(underlying: "Bridge endpoint changed during handshake", serial: serial)
            } catch {
                switch error {
                case BridgeError.httpStatus, BridgeError.malformedEnvelope,
                     BridgeError.applicationError, BridgeError.transport:
                    try cleanupEndpoint(endpoint, preserving: error)
                    if attempt == 0 { continue }
                default:
                    break
                }
                throw error
            }
        }
        preconditionFailure("Handshake attempts exhausted")
    }

    private func performPing(endpoint: Session, finalAttempt: Bool) throws -> PingResult {
        let request = buildRequest(method: "GET", path: "/ping", requiresAuth: false, body: nil, contentType: nil)
        let urlRequest = try makeURLRequest(from: request, endpoint: endpoint)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try urlSession.synchronousDataTask(with: urlRequest)
        } catch {
            if finalAttempt { throw connectionFailure(underlying: error) }
            throw BridgeError.transport(underlying: error.localizedDescription, serial: serial)
        }
        try validateResponse(data: data, response: response)
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
        return result
    }

    /// `GET /a11y_tree_full` → wire envelope with an `ElementNode` payload.
    public func fetchTreeRaw(filter: Bool = false) throws -> Data {
        let path = filter ? "/a11y_tree_full?filter=true" : "/a11y_tree_full"
        let request = buildRequest(method: "GET", path: path, requiresAuth: true, body: nil, contentType: nil)
        return try sendRaw(request: request, expectAuth: true).data
    }

    /// Cache dimensions only if the response still belongs to the current session.
    public func displayInfo() throws -> DisplayMetrics {
        lock.lock()
        let cached = cachedDisplay
        lock.unlock()
        if let cached { return cached }

        let request = buildRequest(method: "GET", path: "/a11y_tree_full?filter=true", requiresAuth: true, body: nil, contentType: nil)
        let response = try sendRaw(request: request, expectAuth: true)
        let envelope: BridgeEnvelope<JSONValue>
        do {
            envelope = try JSONDecoder().decode(BridgeEnvelope<JSONValue>.self, from: response.data)
        } catch {
            throw BridgeError.malformedEnvelope(underlying: error.localizedDescription)
        }
        guard let display = envelope.display else {
            throw BridgeError.malformedEnvelope(underlying: "Bridge tree response missing `display` field")
        }
        lock.lock()
        if session?.generation == response.generation { cachedDisplay = display }
        lock.unlock()
        return display
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
        try? discardEndpoint()
    }

    // MARK: - Internal

    /// How long a new process reuses a session that provider discovery
    /// created, with only an adb forward ownership check. It matches the
    /// default daemon idle timeout: a disk session has the same boundary as
    /// the in-memory session of a warm daemon (issue #188).
    static let restoredSessionTrustWindow: TimeInterval = 600

    private func currentEndpoint() throws -> Session {
        lock.lock()
        defer { lock.unlock() }
        if let session { return session }
        return try establishEndpoint(startupTimeout: nil)
    }

    /// The disk session for this connection. It is read at each use, not
    /// kept from `init`, because another sim-use process can replace it.
    private func diskSession() -> BridgeSession? {
        guard let stored = BridgeSessionStore.read(udid: serial, home: sessionHome),
              stored.connection == connection.identity else { return nil }
        return stored
    }

    private func ownsForward(localPort: Int, remotePort: Int) throws -> Bool {
        try adb.forwards().contains(Adb.Forward(
            serial: serial, localPort: localPort, remote: "tcp:\(remotePort)"
        ))
    }

    /// Create the session for a cold client. The caller holds `lock`, which
    /// serializes discovery and forward creation, never HTTP transport.
    /// A non-nil `startupTimeout` forces provider discovery.
    private func establishEndpoint(startupTimeout: TimeInterval?) throws -> Session {
        try BridgeSessionStore.withExclusiveAccess(udid: serial, home: sessionHome) {
            try establishLockedEndpoint(startupTimeout: startupTimeout)
        }
    }

    /// Both the instance lock and shared file lock are held here. A host-only
    /// change leaves an old forward on this adb server; remove it before reuse.
    private func establishLockedEndpoint(startupTimeout: TimeInterval?) throws -> Session {
        if let cached = BridgeSessionStore.read(udid: serial, home: sessionHome),
           cached.connection != connection.identity, cached.adbServer == connection.adbServer {
            if try ownsForward(localPort: cached.localPort, remotePort: cached.remotePort) {
                try adb.forwardRemove(serial: serial, localPort: cached.localPort)
            }
            BridgeSessionStore.invalidate(udid: serial, home: sessionHome)
        }
        let restored = diskSession()
        // A failed list keeps the disk session for the next call to check.
        let ownsRestored = try restored.map {
            try ownsForward(localPort: $0.localPort, remotePort: $0.remotePort)
        } ?? false

        if startupTimeout == nil, ownsRestored, let restored,
           let discoveredAt = restored.discoveredAt,
           (0..<Self.restoredSessionTrustWindow).contains(Date().timeIntervalSince(discoveredAt)) {
            // The disk session stays as written: reuse must not move its discovery time.
            return adopt(token: restored.token, localPort: restored.localPort, remotePort: restored.remotePort)
        }

        let discovered = try AuthTokenFetcher.fetchEndpoint(
            adb: adb, serial: serial, timeout: startupTimeout ?? 0
        )
        var localPort: Int?
        if ownsRestored, let restored {
            if restored.remotePort == discovered.remotePort {
                localPort = restored.localPort
            } else {
                try adb.forwardRemove(serial: serial, localPort: restored.localPort)
            }
        }
        let port = try localPort ?? adb.forward(serial: serial, remotePort: discovered.remotePort)
        let endpoint = adopt(token: discovered.token, localPort: port, remotePort: discovered.remotePort)
        BridgeSessionStore.write(BridgeSession(
            token: endpoint.token, localPort: endpoint.localPort, remotePort: endpoint.remotePort,
            connection: connection.identity, adbServer: connection.adbServer, discoveredAt: Date()
        ), udid: serial, home: sessionHome)
        return endpoint
    }

    private func adopt(token: String, localPort: Int, remotePort: Int) -> Session {
        generation &+= 1
        let endpoint = Session(generation: generation, token: token, localPort: localPort, remotePort: remotePort)
        session = endpoint
        verifiedPing = nil
        cachedDisplay = nil
        return endpoint
    }

    private func discardEndpoint(generation failedGeneration: UInt64? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        // A delayed failure belongs to its original session, not a replacement.
        if let failedGeneration, session?.generation != failedGeneration { return }
        try BridgeSessionStore.withExclusiveAccess(udid: serial, home: sessionHome) {
            try discardLockedEndpoint()
        }
    }

    /// The shared lock protects the disk snapshot until deletion is complete.
    private func discardLockedEndpoint() throws {
        let stored = diskSession()
        // A client that has not connected owns the forward of its disk session.
        let ports = session.map { ($0.localPort, $0.remotePort) }
            ?? stored.map { ($0.localPort, $0.remotePort) }
        if let (localPort, remotePort) = ports,
           try ownsForward(localPort: localPort, remotePort: remotePort) {
            try adb.forwardRemove(serial: serial, localPort: localPort)
        }
        session = nil
        verifiedPing = nil
        cachedDisplay = nil
        // Another process can have replaced the disk session. That record is
        // the only reference to its forward, so it must stay.
        if let (localPort, remotePort) = ports, let stored,
           stored.localPort == localPort, stored.remotePort == remotePort {
            BridgeSessionStore.invalidate(udid: serial, home: sessionHome)
        }
    }

    /// Discard the failed endpoint. If the ownership check fails, the session
    /// stays for the next call to check, and the caller gets `failure`.
    private func cleanupEndpoint(_ endpoint: Session, preserving failure: Error) throws {
        do {
            try discardEndpoint(generation: endpoint.generation)
        } catch {
            throw failure
        }
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

    /// Build the URL and bearer from the same immutable session.
    private func makeURLRequest(from request: Request, endpoint: Session) throws -> URLRequest {
        let port = endpoint.localPort
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
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private struct RawResponse {
        let data: Data
        let generation: UInt64
    }

    private func sendRaw(
        request: Request, expectAuth: Bool, allowReconnect: Bool = true
    ) throws -> RawResponse {
        let endpoint = try verifiedEndpoint().session
        let urlRequest = try makeURLRequest(from: request, endpoint: endpoint)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try urlSession.synchronousDataTask(with: urlRequest)
        } catch {
            let failure = connectionFailure(underlying: error)
            try cleanupEndpoint(endpoint, preserving: failure)
            let definitelyNotSent = (error as? URLError)?.code == .cannotConnectToHost
            if allowReconnect && (request.method == "GET" || definitelyNotSent) {
                return try sendRaw(request: request, expectAuth: expectAuth, allowReconnect: false)
            }
            // A POST may already have executed. Report its unknown outcome.
            throw failure
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 401, expectAuth {
            let failure = BridgeError.httpStatus(code: 401, body: String(data: data, encoding: .utf8) ?? "")
            try cleanupEndpoint(endpoint, preserving: failure)
            if allowReconnect {
                return try sendRaw(request: request, expectAuth: expectAuth, allowReconnect: false)
            }
            throw failure
        }
        switch classify(data: data, response: response) {
        case .success:
            return RawResponse(data: data, generation: endpoint.generation)
        case .bridgeFailure(let failure):
            throw failure
        case .otherListener(let failure):
            // The cached port no longer reaches the bridge. Drop the endpoint so
            // the next request discovers again. Only a GET is repeated: a POST
            // is reported, because this classification is an inference and a
            // repeated action is worse than a reported failure.
            try cleanupEndpoint(endpoint, preserving: failure)
            if allowReconnect && request.method == "GET" {
                return try sendRaw(request: request, expectAuth: expectAuth, allowReconnect: false)
            }
            throw failure
        }
    }

    private enum ResponseClass {
        case success
        /// A failure that the bridge reported. The endpoint is still valid.
        case bridgeFailure(BridgeError)
        /// Not a bridge response. The bridge reports every error as a JSON
        /// envelope (`HttpServer.kt`, `ActionRouter.errorJson`), so another
        /// shape comes from another listener on the cached port.
        case otherListener(BridgeError)
    }

    private func classify(data: Data, response: URLResponse) -> ResponseClass {
        guard let http = response as? HTTPURLResponse else {
            return .otherListener(.transport(underlying: "Non-HTTP response from bridge", serial: serial))
        }
        guard http.statusCode != 200 else { return .success }
        let status = BridgeError.httpStatus(code: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        struct Empty: Decodable {}
        guard let envelope = try? JSONDecoder().decode(BridgeEnvelope<Empty>.self, from: data) else {
            return .otherListener(status)
        }
        if http.statusCode != 401, !envelope.isSuccess {
            return .bridgeFailure(.applicationError(
                status: envelope.status, code: envelope.code, message: envelope.error
            ))
        }
        return .bridgeFailure(status)
    }

    private func validateResponse(data: Data, response: URLResponse) throws {
        switch classify(data: data, response: response) {
        case .success: return
        case .bridgeFailure(let failure), .otherListener(let failure): throw failure
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
        let data = try sendRaw(request: request, expectAuth: expectAuth).data
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
