// SPDX-License-Identifier: Apache-2.0
import Foundation
import Network

// Minimal TCP+HTTP/1.1 server hosted on Network.framework. Bound to
// the loopback interface only — the Viewer is a developer tool for
// the current user, not a network-exposed service. One request per
// connection: accept → buffer → parse → dispatch → write response →
// close. Routes are plain async closures so handlers can do whatever
// work (incl. shelling out to `sim-use`) without blocking the listener.

final class HTTPServer {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let queue = DispatchQueue(label: "sim-use.viewer.http")
    private var routes: [(method: String, prefix: String, exact: Bool, handler: Handler)] = []
    private var fallbackHandler: Handler?

    private(set) var boundPort: UInt16 = 0

    init(port: UInt16) throws {
        let endpointPort: NWEndpoint.Port
        if port == 0 {
            endpointPort = .any
        } else if let p = NWEndpoint.Port(rawValue: port) {
            endpointPort = p
        } else {
            throw HTTPServerError.invalidPort(port)
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback-only binding: the listener will only accept packets
        // routed through `lo0`, so this socket is unreachable from the
        // LAN / Wi-Fi / a peer container. Defence in depth — the API
        // surface is also benign, but there's no reason to expose it.
        params.requiredInterfaceType = .loopback

        self.listener = try NWListener(using: params, on: endpointPort)
    }

    // MARK: - Routing

    func get(_ path: String, handler: @escaping Handler) {
        routes.append((method: "GET", prefix: path, exact: true, handler: handler))
    }

    func post(_ path: String, handler: @escaping Handler) {
        routes.append((method: "POST", prefix: path, exact: true, handler: handler))
    }

    /// Catch-all for static-file serving etc. — matched after all exact
    /// routes have missed.
    func fallback(_ handler: @escaping Handler) {
        fallbackHandler = handler
    }

    // MARK: - Lifecycle

    func start() async throws {
        let started = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let p = self.listener.port?.rawValue ?? 0
                    self.boundPort = p
                    continuation.yield(p)
                    continuation.finish()
                case .failed(let error):
                    continuation.finish()
                    // Surface fatal listener errors to stderr — the
                    // command-level catch will print a friendlier hint
                    // around it.
                    FileHandle.standardError.write(Data("sim-use viewer: listener failed: \(error)\n".utf8))
                case .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.start(queue: queue)
        }
        // Wait until the listener actually binds and reports its port.
        var port: UInt16 = 0
        for await p in started {
            port = p
            break
        }
        guard port != 0 else {
            throw HTTPServerError.listenerFailedToBind
        }
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        readRequest(on: connection, buffer: Data())
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        // Cap the request buffer so a malformed / hostile client can't
        // make us accumulate unbounded memory. 1 MiB is roomy for any
        // headers + JSON body the Viewer will realistically send.
        let limit = 1 << 20
        if buffer.count > limit {
            send(.plain(413, "request too large"), on: connection)
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if let error = error {
                // EOF or peer reset — give up on this connection.
                _ = error
                connection.cancel()
                return
            }
            var nextBuffer = buffer
            if let chunk, !chunk.isEmpty {
                nextBuffer.append(chunk)
            }
            switch HTTPParser.parse(nextBuffer) {
            case .needMoreHeaders, .needMoreBody:
                if isComplete {
                    self.send(.plain(400, "incomplete request"), on: connection)
                } else {
                    self.readRequest(on: connection, buffer: nextBuffer)
                }
            case .invalid(let reason):
                self.send(.plain(400, reason), on: connection)
            case .ready(let request, _):
                Task {
                    let response = await self.dispatch(request)
                    self.send(response, on: connection)
                }
            }
        }
    }

    private func dispatch(_ request: HTTPRequest) async -> HTTPResponse {
        // HEAD is GET-without-a-body. Reuse the GET pipeline (including
        // the static-file fallback) so health probes, proxies, and the
        // odd `curl -I` all see consistent status + headers.
        if request.method == "HEAD" {
            let asGet = HTTPRequest(
                method: "GET",
                path: request.path,
                query: request.query,
                headers: request.headers,
                body: request.body
            )
            let response = await dispatch(asGet)
            return response.headOnly()
        }
        for route in routes where route.method == request.method && route.prefix == request.path {
            return await route.handler(request)
        }
        if let fallbackHandler {
            return await fallbackHandler(request)
        }
        // GET on an unmapped path is a 404; everything else is 405 so
        // tooling can tell "you got the verb wrong" apart from "the
        // route doesn't exist at all".
        if request.method == "GET" {
            return .plain(404, "not found: \(request.path)")
        }
        return .plain(405, "method not allowed: \(request.method) \(request.path)")
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialize(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum HTTPServerError: Error, CustomStringConvertible {
    case invalidPort(UInt16)
    case listenerFailedToBind

    var description: String {
        switch self {
        case .invalidPort(let p):
            return "invalid port: \(p)"
        case .listenerFailedToBind:
            return "HTTP listener failed to bind"
        }
    }
}