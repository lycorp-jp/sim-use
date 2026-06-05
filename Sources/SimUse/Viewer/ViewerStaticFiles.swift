// SPDX-License-Identifier: Apache-2.0
import Foundation

// Serve the Vite-built Viewer SPA out of `Bundle.module`. The dist tree
// is placed under `Resources/viewer/` by `scripts/build-viewer.sh`;
// SwiftPM mirrors it into the resource bundle at build time. SPA
// fallback: any non-/api GET that doesn't resolve to a file returns
// `index.html` so client-side routing (if added later) keeps working.

enum ViewerStaticFiles {
    /// Root of the bundled Viewer SPA tree, e.g.
    /// `…/SimUse_SimUse.bundle/viewer/`.
    static var rootURL: URL? {
        Bundle.module.resourceURL?.appendingPathComponent("viewer", isDirectory: true)
    }

    static func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.method == "GET" else {
            return .plain(405, "method not allowed: \(request.method) \(request.path)")
        }
        guard let root = rootURL,
              FileManager.default.fileExists(atPath: root.path)
        else {
            return .plain(
                500,
                "Viewer assets are missing from this build. Run scripts/build-viewer.sh and rebuild."
            )
        }
        let relative = normalize(request.path)
        if let response = try? readFile(at: root.appendingPathComponent(relative)) {
            return response
        }
        // SPA fallback: only for paths that look like a client route,
        // not for /assets/* lookups that genuinely missed (otherwise a
        // 404'd JS chunk would silently turn into a HTML body and break
        // the page in confusing ways).
        if shouldFallbackToIndex(path: relative),
           let response = try? readFile(at: root.appendingPathComponent("index.html"))
        {
            return response
        }
        return .plain(404, "not found: \(request.path)")
    }

    // MARK: - Internals

    private static func normalize(_ path: String) -> String {
        // Reject path-traversal attempts and absolute paths. The
        // `path` here comes from `HTTPParser.splitTarget` which keeps
        // the leading slash. Stripping it lets `URL(fileURLWithPath:)`
        // produce a child URL of `root`.
        var trimmed = path
        if trimmed.hasPrefix("/") { trimmed.removeFirst() }
        if trimmed.isEmpty { trimmed = "index.html" }
        // The browser may send queries / fragments but `splitTarget`
        // strips those — this is just defense in depth.
        if let q = trimmed.firstIndex(of: "?") { trimmed = String(trimmed[..<q]) }
        if let h = trimmed.firstIndex(of: "#") { trimmed = String(trimmed[..<h]) }
        return trimmed
    }

    private static func shouldFallbackToIndex(path: String) -> Bool {
        // Anything that looks like a file extension is a real asset
        // request — don't lie about its existence by handing back
        // index.html.
        let last = (path as NSString).lastPathComponent
        return !last.contains(".")
    }

    private static func readFile(at url: URL) throws -> HTTPResponse? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue
        else { return nil }
        // Sanity check: ensure the resolved URL is still under the
        // resource root. Catches a `..` traversal sneaking through.
        if let root = rootURL,
           !url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path)
        {
            return nil
        }
        let data = try Data(contentsOf: url)
        let contentType = mimeType(for: url.pathExtension.lowercased())
        // Hashed Vite asset URLs (e.g. /assets/index-Cc3gMmeJ.js) can
        // be cached aggressively; index.html must never be cached.
        let cache = url.pathExtension.lowercased() == "html"
            ? "no-store"
            : "public, max-age=31536000, immutable"
        return .data(data, contentType: contentType, cacheControl: cache)
    }

    private static func mimeType(for ext: String) -> String {
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "text/javascript; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "svg":         return "image/svg+xml"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp":        return "image/webp"
        case "ico":         return "image/x-icon"
        case "map":         return "application/json; charset=utf-8"
        case "woff":        return "font/woff"
        case "woff2":       return "font/woff2"
        case "ttf":         return "font/ttf"
        default:            return "application/octet-stream"
        }
    }
}