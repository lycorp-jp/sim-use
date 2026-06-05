// SPDX-License-Identifier: Apache-2.0
import AppKit
import ArgumentParser
import Foundation

/// Launches the Viewer: a tiny local HTTP server that hosts the
/// React/Vite SPA bundled into this binary's resources, plus three API
/// endpoints that mirror `Tools/Viewer/server/server.mjs`. Replaces the
/// old Node-based dev story for everyday use — `sim-use viewer` is the
/// only command users need, no `npm install` involved.
///
/// The dev server (Vite + Express in `Tools/Viewer`) stays useful for
/// Viewer front-end development. This command runs the *built* output.
struct Viewer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "viewer",
        abstract: "Open the Viewer in your browser: visualise the live UI tree of a booted simulator alongside what sim-use sees.",
        discussion: """
        The Viewer is a local-only web app for debugging what sim-use's
        accessibility scrape actually exposes — useful while writing
        agent scripts or chasing missing labels. It hosts:

          /                — the React SPA (built into this binary)
          /api/devices     — currently usable simulators (mirrors `sim-use devices --json`)
          /api/snapshot    — one UI snapshot (mirrors `sim-use describe-ui --json`)
          /api/tap         — replay a tap by @N alias (mirrors `sim-use tap`)

        The server binds to 127.0.0.1 only — nothing on your LAN can
        reach it. Default port is auto-assigned; pass `--port` to pin.

        Examples:
          sim-use viewer                         # auto-port, auto-open in default browser
          sim-use viewer --port 4173             # pin the port (e.g. for bookmarking)
          sim-use viewer --no-open               # print URL only, useful in scripts / CI
        """
    )

    @Option(name: .customLong("port"), help: "TCP port to bind on 127.0.0.1. 0 (default) lets the OS pick a free port.")
    var port: UInt16 = 0

    @Flag(name: .customLong("no-open"), help: "Don't auto-open the default browser. Print the URL to stdout instead.")
    var noOpen: Bool = false

    @MainActor
    func run() async throws {
        guard let viewerRoot = ViewerStaticFiles.rootURL,
              FileManager.default.fileExists(atPath: viewerRoot.appendingPathComponent("index.html").path)
        else {
            throw ValidationError("""
                The Viewer SPA assets were not bundled into this build.
                Run `scripts/build-viewer.sh` and `swift build` again,
                or reinstall sim-use from a release tarball.
                """)
        }

        let executable: URL
        do {
            executable = try ViewerAPIHandlers.resolveSelfExecutable()
        } catch {
            throw ValidationError("Could not locate sim-use binary path: \(error)")
        }
        let api = ViewerAPIHandlers(executable: executable)

        let server = try HTTPServer(port: port)
        server.get("/api/devices") { req in await api.devices(req) }
        server.get("/api/snapshot") { req in await api.snapshot(req) }
        server.post("/api/tap") { req in await api.tap(req) }
        server.fallback { req in await ViewerStaticFiles.handle(req) }

        try await server.start()
        let boundPort = server.boundPort
        let url = URL(string: "http://127.0.0.1:\(boundPort)/")!

        FileHandle.standardOutput.write(Data("sim-use viewer listening on \(url.absoluteString)\n".utf8))
        FileHandle.standardOutput.write(Data("Press Ctrl-C to stop.\n".utf8))

        if !noOpen {
            NSWorkspace.shared.open(url)
        }

        // Block forever — SIGINT / SIGTERM end the process. We don't
        // install a signal handler ourselves: the default behaviour
        // (Foundation tears down the listener, NWConnections cancel
        // cleanly) is good enough for a local dev tool.
        try await Task.sleep(nanoseconds: .max)
    }
}