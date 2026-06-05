// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge

import com.linecorp.simuse.devicebridge.server.HttpServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream

/**
 * Byte-level tests for `HttpServer.parseRequest`. The parser was
 * previously char-based (`BufferedReader`) which mis-reads
 * `Content-Length` for any non-ASCII body — content-length is in
 * bytes, and a `CharArray(N)` of N chars consumes a variable
 * number of bytes depending on multi-byte UTF-8 sequences.
 *
 * Pinning the contract here so the parser stays byte-correct
 * across future refactors.
 */
class HttpServerParseRequestTest {

    private val server = HttpServer(port = 0, router = mockRouter())

    private fun mockRouter() = com.linecorp.simuse.devicebridge.server.ActionRouter(
        serviceProvider = { null },
        authManager = mockAuthManager()
    )

    private fun mockAuthManager() = io.mockk.mockk<com.linecorp.simuse.devicebridge.config.AuthManager>(relaxed = true)

    private fun parse(raw: String): HttpServer.HttpRequest? {
        val stream = ByteArrayInputStream(raw.toByteArray(Charsets.UTF_8))
        return server.parseRequest(stream)
    }

    @Test
    fun simpleGetWithoutBody() {
        val req = parse("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
        assertNotNull(req)
        assertEquals("GET", req!!.method)
        assertEquals("/ping", req.path)
    }

    @Test
    fun postWithFormBody() {
        val body = "x=10&y=20"
        val req = parse(
            "POST /tap HTTP/1.1\r\n" +
                "Content-Type: application/x-www-form-urlencoded\r\n" +
                "Content-Length: ${body.toByteArray(Charsets.UTF_8).size}\r\n" +
                "\r\n" +
                body
        )
        assertNotNull(req)
        assertEquals("10", req!!.params["x"])
        assertEquals("20", req.params["y"])
    }

    /// Regression for the original bug: a body whose char count
    /// differs from its byte count (multi-byte UTF-8). The previous
    /// `BufferedReader` parser would mis-count and truncate the
    /// body or read past it; the byte-level parser must round-trip
    /// the exact bytes.
    @Test
    fun postWithMultibyteUtf8Body() {
        val text = "こんにちは"  // 5 chars, 15 bytes in UTF-8
        val body = "base64_text=${java.net.URLEncoder.encode(text, "UTF-8")}"
        val byteLen = body.toByteArray(Charsets.UTF_8).size
        val req = parse(
            "POST /keyboard/input HTTP/1.1\r\n" +
                "Content-Type: application/x-www-form-urlencoded\r\n" +
                "Content-Length: $byteLen\r\n" +
                "\r\n" +
                body
        )
        assertNotNull(req)
        assertEquals(text, req!!.params["base64_text"])
    }

    @Test
    fun rejectsExcessiveContentLength() {
        // parseRequest throws RuntimeException(BadRequestException)
        // on oversize Content-Length so the handler can surface a
        // 413. Catch and pin the contract.
        try {
            parse(
                "POST /paste HTTP/1.1\r\n" +
                    "Content-Length: ${HttpServer.MAX_BODY_BYTES + 1}\r\n" +
                    "\r\n"
            )
            org.junit.Assert.fail("expected BadRequestException for oversize content-length")
        } catch (e: RuntimeException) {
            assertTrue(
                "expected message to mention byte cap; got: ${e.message}",
                (e.message ?: "").contains("byte cap")
            )
        }
    }

    @Test
    fun rejectsHugeHeaderFlood() {
        val flood = "X-Pad: " + "A".repeat(HttpServer.MAX_HEADER_BYTES + 1) + "\r\n"
        try {
            parse("GET /ping HTTP/1.1\r\n$flood\r\n")
            org.junit.Assert.fail("expected BadRequestException for header flood")
        } catch (e: RuntimeException) {
            assertTrue((e.message ?: "").contains("byte cap"))
        }
    }

    @Test
    fun parsesQueryString() {
        val req = parse("GET /a11y_tree_full?filter=true HTTP/1.1\r\nHost: localhost\r\n\r\n")
        assertNotNull(req)
        assertEquals("/a11y_tree_full", req!!.path)
        assertEquals("true", req.params["filter"])
    }
}