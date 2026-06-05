// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge.server

import android.util.Log
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Minimal HTTP/1.1 server backed by a raw `ServerSocket`.
 *
 * Replicates csat's `HttpServer` shape (same pool layout, same parser,
 * same status-text table — including 504 which NanoHTTPD's enum can't
 * express natively). Form-urlencoded bodies and `application/json`
 * (for `/gesture`'s `strokes` array) both flow into a single `params`
 * map that the router consumes.
 *
 * Concurrency model lifted from csat:
 *   - One accept-loop thread, never blocked by handlers.
 *   - Fixed handler pool of 4 — the AccessibilityService Binder path
 *     is the real bottleneck, so wider parallelism doesn't help.
 *   - `soTimeout` on the socket so a stuck handler can't pin its
 *     connection indefinitely.
 */
class HttpServer(
    private val port: Int,
    private val router: ActionRouter,
) {
    private var serverSocket: ServerSocket? = null
    private val running = AtomicBoolean(false)
    private var executor: ExecutorService? = null
    private var acceptThread: Thread? = null
    private val activeHandlers = AtomicInteger(0)
    private val totalRequests = AtomicInteger(0)

    val isRunning: Boolean get() = running.get()

    fun start() {
        if (running.getAndSet(true)) return

        val pool = Executors.newFixedThreadPool(HANDLER_POOL_SIZE)
        executor = pool

        acceptThread = Thread({
            try {
                val ss = ServerSocket()
                ss.reuseAddress = true
                // Bind to loopback only. `adb forward tcp:LOCAL tcp:REMOTE`
                // reaches us through 127.0.0.1, so wildcard binding only
                // adds an attack surface: a Wi-Fi-connected device would
                // otherwise expose the bridge to any LAN peer that knows
                // the auth token.
                ss.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), port))
                serverSocket = ss
                Log.i(TAG, "HTTP server listening on 127.0.0.1:$port")
                while (running.get()) {
                    try {
                        val socket = ss.accept()
                        pool.execute { handleConnection(socket) }
                    } catch (e: Exception) {
                        if (running.get()) Log.w(TAG, "Accept error: ${e.message}")
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Server start failed", e)
                running.set(false)
            }
        }, "SimuseHttpServer-accept").also { it.start() }
    }

    fun stop() {
        if (!running.getAndSet(false)) return
        Log.i(TAG, "stopping (total_requests=${totalRequests.get()}, active=${activeHandlers.get()})")
        try { serverSocket?.close() } catch (_: Exception) {}
        acceptThread?.interrupt()
        acceptThread = null
        // `shutdown()` lets in-flight handlers finish writing
        // their response within `SHUTDOWN_GRACE_MS`; then
        // `shutdownNow()` interrupts anything still running.
        // Without the await, `stop()` followed quickly by a
        // re-`start()` (the SimuseAccessibilityService onUnbind
        // → onServiceConnected cycle) could race the handler
        // pool's worker threads against the new pool's accept
        // queue and lose responses mid-flight.
        executor?.let { pool ->
            pool.shutdown()
            try {
                if (!pool.awaitTermination(SHUTDOWN_GRACE_MS, TimeUnit.MILLISECONDS)) {
                    pool.shutdownNow()
                }
            } catch (_: InterruptedException) {
                pool.shutdownNow()
                Thread.currentThread().interrupt()
            }
        }
        executor = null
    }

    private fun handleConnection(socket: Socket) {
        val reqNum = totalRequests.incrementAndGet()
        val active = activeHandlers.incrementAndGet()
        try {
            socket.use { s ->
                s.soTimeout = SOCKET_TIMEOUT_MS
                val request = parseRequest(BufferedInputStream(s.getInputStream())) ?: return
                if (active >= HANDLER_POOL_SIZE) {
                    Log.w(TAG, "Handler pool saturated: active=$active/$HANDLER_POOL_SIZE for ${request.method} ${request.path} (#$reqNum)")
                }
                val response = router.route(
                    method = request.method,
                    path = request.path,
                    params = request.params,
                    headers = request.headers,
                )
                writeResponse(s, response)
            }
        } catch (e: BadRequestException) {
            Log.w(TAG, "Bad request (req #$reqNum): ${e.message}")
            try {
                writeResponse(socket, HttpResponse(e.statusCode, """{"status":"error","error":"${e.message}"}"""))
            } catch (_: Exception) {}
        } catch (e: Exception) {
            Log.w(TAG, "Connection error (req #$reqNum, active=$active): ${e.message}")
        } finally {
            activeHandlers.decrementAndGet()
        }
    }

    // ── HTTP parsing ────────────────────────────────────────────

    /**
     * Byte-level request parser. The previous `BufferedReader`-based
     * version decoded the stream as chars before content-length had
     * been read, which breaks any body containing multi-byte UTF-8 —
     * `Content-Length: 12` (bytes) and `reader.read(charArr, 0, 12)`
     * disagree on what "12" means once the body contains a single
     * emoji (4 bytes / 2 chars or so). This parser reads bytes for
     * the header section (ASCII per HTTP spec) and the body
     * separately, then decodes the body as UTF-8 at the boundary.
     *
     * Also enforces:
     *   * `MAX_HEADER_BYTES` total header size (no slow-loris with
     *     megabyte-sized header floods).
     *   * `MAX_BODY_BYTES` content-length cap (`413 Payload Too
     *     Large` on overflow rather than allocating arbitrary
     *     gigabytes on `Content-Length: 2147483647`).
     */
    internal fun parseRequest(input: InputStream): HttpRequest? {
        val headerBytes = readHeaderBytes(input) ?: return null
        val headerText = String(headerBytes, Charsets.US_ASCII)
        val lines = headerText.split("\r\n")
        if (lines.isEmpty()) return null

        val requestLine = lines[0]
        val parts = requestLine.split(" ", limit = 3)
        if (parts.size < 2) return null
        val method = parts[0].uppercase()
        val rawPath = parts[1]

        val (path, queryString) = if ("?" in rawPath) {
            val idx = rawPath.indexOf("?")
            rawPath.substring(0, idx) to rawPath.substring(idx + 1)
        } else {
            rawPath to ""
        }

        val headers = mutableMapOf<String, String>()
        for (line in lines.drop(1)) {
            if (line.isEmpty()) continue
            val colon = line.indexOf(":")
            if (colon > 0) {
                val key = line.substring(0, colon).trim().lowercase()
                val value = line.substring(colon + 1).trim()
                headers[key] = value
            }
        }

        val contentLength = headers["content-length"]?.toIntOrNull() ?: 0
        if (contentLength < 0) {
            throw BadRequestException(400, "negative content-length: $contentLength")
        }
        if (contentLength > MAX_BODY_BYTES) {
            throw BadRequestException(
                413,
                "content-length $contentLength exceeds ${MAX_BODY_BYTES} byte cap",
            )
        }
        val body = if (contentLength > 0) {
            val buf = ByteArray(contentLength)
            var read = 0
            while (read < contentLength) {
                val n = input.read(buf, read, contentLength - read)
                if (n == -1) break
                read += n
            }
            String(buf, 0, read, Charsets.UTF_8)
        } else {
            ""
        }

        val params = mutableMapOf<String, String>()
        if (queryString.isNotEmpty()) params.putAll(parseFormUrlEncoded(queryString))
        if (body.isNotEmpty()) {
            val contentType = headers["content-type"] ?: ""
            if (contentType.contains("application/json")) {
                // `/gesture` uses JSON body; surface the raw `strokes`
                // array as a string so the router parses it with JSON.
                try {
                    val json = org.json.JSONObject(body)
                    if (json.has("strokes")) {
                        params["strokes"] = json.getJSONArray("strokes").toString()
                    }
                } catch (_: Exception) {
                }
            } else {
                params.putAll(parseFormUrlEncoded(body))
            }
        }

        return HttpRequest(method, path, params, headers)
    }

    /**
     * Reads up to and including the `\r\n\r\n` header terminator,
     * returning all bytes BEFORE the terminator. Returns null on
     * EOF before any data was read. Caps total at
     * `MAX_HEADER_BYTES` and throws `BadRequestException` (413)
     * on overflow so a slow-loris client can't dribble megabytes
     * of header at us.
     */
    private fun readHeaderBytes(input: InputStream): ByteArray? {
        val out = ByteArrayOutputStream()
        var lastFour = 0  // rolling buffer of the last 4 bytes
        var byte = input.read()
        if (byte == -1) return null
        while (byte != -1) {
            out.write(byte)
            if (out.size() > MAX_HEADER_BYTES) {
                throw BadRequestException(
                    413,
                    "request headers exceed ${MAX_HEADER_BYTES} byte cap",
                )
            }
            lastFour = (lastFour shl 8) or (byte and 0xFF)
            // 0x0D0A0D0A == "\r\n\r\n"
            if (lastFour == 0x0D0A0D0A) {
                val bytes = out.toByteArray()
                // Strip the trailing \r\n\r\n that terminates headers.
                return bytes.copyOf(bytes.size - 4)
            }
            byte = input.read()
        }
        // Stream ended before headers terminated — treat the
        // accumulated bytes as headers anyway (lenient parser; the
        // header-line split tolerates missing CRLF).
        return out.toByteArray()
    }

    private class BadRequestException(val statusCode: Int, message: String) : RuntimeException(message)

    private fun parseFormUrlEncoded(data: String): Map<String, String> =
        Companion.parseFormUrlEncoded(data)

    // ── HTTP response writer ────────────────────────────────────

    private fun writeResponse(socket: Socket, response: HttpResponse) {
        val statusText = HTTP_STATUS_TEXTS[response.statusCode] ?: "Unknown"
        val bodyBytes = response.body.toByteArray(Charsets.UTF_8)

        val header = buildString {
            append("HTTP/1.1 ${response.statusCode} $statusText\r\n")
            append("Content-Type: application/json; charset=utf-8\r\n")
            append("Content-Length: ${bodyBytes.size}\r\n")
            append("Connection: close\r\n")
            append("\r\n")
        }

        socket.getOutputStream().apply {
            write(header.toByteArray(Charsets.UTF_8))
            write(bodyBytes)
            flush()
        }
    }

    internal data class HttpRequest(
        val method: String,
        val path: String,
        val params: Map<String, String>,
        val headers: Map<String, String>,
    )

    companion object {
        private const val TAG = "SimuseHttpServer"
        private const val SOCKET_TIMEOUT_MS = 8_000
        private const val HANDLER_POOL_SIZE = 4
        private const val SHUTDOWN_GRACE_MS = 2_000L

        // 8 KiB is generous for a real HTTP request line + header
        // set (typical sim-use bridge requests fit in <1 KiB).
        // Past that we're either being slow-loris'd or a client
        // is dumping a megabyte-of-headers attack — refuse and
        // free the socket.
        internal const val MAX_HEADER_BYTES = 8 * 1024

        // 4 MiB body cap. Realistic bridge bodies are tap/swipe
        // params (<100 B), `keyboard/input` base64 text (a few KB
        // for normal paste), and `/gesture` stroke arrays (≤10
        // strokes × tiny). A `Content-Length: 2147483647` flood
        // without the cap would have us trying to allocate a 2 GiB
        // CharArray.
        internal const val MAX_BODY_BYTES = 4 * 1024 * 1024

        internal fun parseFormUrlEncoded(data: String): Map<String, String> {
            val result = mutableMapOf<String, String>()
            for (pair in data.split("&")) {
                val eq = pair.indexOf("=")
                if (eq > 0) {
                    val key = URLDecoder.decode(pair.substring(0, eq), "UTF-8")
                    val value = URLDecoder.decode(pair.substring(eq + 1), "UTF-8")
                    result[key] = value
                }
            }
            return result
        }

        private val HTTP_STATUS_TEXTS = mapOf(
            200 to "OK",
            400 to "Bad Request",
            401 to "Unauthorized",
            404 to "Not Found",
            500 to "Internal Server Error",
            503 to "Service Unavailable",
            504 to "Gateway Timeout",
        )
    }
}