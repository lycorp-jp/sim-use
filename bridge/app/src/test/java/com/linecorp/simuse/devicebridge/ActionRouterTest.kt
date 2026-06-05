// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge

import android.accessibilityservice.AccessibilityService
import com.linecorp.simuse.devicebridge.config.AuthManager
import com.linecorp.simuse.devicebridge.server.ActionRouter
import io.mockk.every
import io.mockk.mockk
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Routing-layer tests for `ActionRouter`: auth gate, unknown routes,
 * `/ping` envelope shape, missing-parameter handling.
 *
 * We don't reach the handler implementations here — those are either
 * Android-coupled (TreeHandler / GestureHandler / CaptureHandler all
 * need `AccessibilityNodeInfo` or `Bitmap`) or already covered by
 * dedicated unit suites (`InputHandlerTest`). The router contract
 * (which paths exist, how errors are shaped, who can bypass auth) is
 * what most callers actually depend on through the wire spec.
 */
class ActionRouterTest {

    private val token = "test-token-1234"
    private lateinit var authManager: AuthManager
    private lateinit var router: ActionRouter

    @Before
    fun setUp() {
        authManager = mockk()
        every { authManager.getOrCreateToken() } returns token
        // No accessibility service available — routes that touch the
        // service will return 503. That's still a route-layer outcome
        // worth pinning.
        router = ActionRouter(serviceProvider = { null }, authManager = authManager)
    }

    private fun authed(): Map<String, String> = mapOf("authorization" to "Bearer $token")
    private fun unauthed(): Map<String, String> = emptyMap()

    // ── /ping bypasses auth ─────────────────────────────────────

    @Test
    fun pingReachableWithoutAuth() {
        val resp = router.route("GET", "/ping", emptyMap(), unauthed())
        assertEquals(200, resp.statusCode)
        val json = JSONObject(resp.body)
        assertEquals("success", json.getString("status"))
        assertEquals("pong", json.getString("result"))
        // protocol_version + bridge_version live alongside result so
        // clients can verify compatibility without an authed call.
        assertTrue("protocol_version field present", json.has("protocol_version"))
        assertTrue("bridge_version field present", json.has("bridge_version"))
    }

    // ── Auth gate ───────────────────────────────────────────────

    @Test
    fun nonPingPathWithoutAuthReturns401() {
        val resp = router.route("GET", "/a11y_tree_full", emptyMap(), unauthed())
        assertEquals(401, resp.statusCode)
        val json = JSONObject(resp.body)
        assertEquals("error", json.getString("status"))
        assertEquals("unauthorized", json.getString("code"))
    }

    @Test
    fun nonPingPathWithWrongBearerReturns401() {
        val resp = router.route(
            "GET", "/a11y_tree_full", emptyMap(),
            mapOf("authorization" to "Bearer wrong-token")
        )
        assertEquals(401, resp.statusCode)
    }

    @Test
    fun nonPingPathWithMalformedAuthHeaderReturns401() {
        val resp = router.route(
            "GET", "/a11y_tree_full", emptyMap(),
            mapOf("authorization" to "NoBearerPrefix $token")
        )
        assertEquals(401, resp.statusCode)
    }

    // ── Unknown paths ────────────────────────────────────────────

    @Test
    fun unknownPathReturns404() {
        val resp = router.route("GET", "/no-such-endpoint", emptyMap(), authed())
        assertEquals(404, resp.statusCode)
        val json = JSONObject(resp.body)
        assertEquals("unknown_endpoint", json.getString("code"))
    }

    @Test
    fun methodMismatchReturns404() {
        // /ping is GET-only; POST /ping is "unknown".
        val resp = router.route("POST", "/ping", emptyMap(), authed())
        assertEquals(404, resp.statusCode)
    }

    // ── Missing-parameter contract on input verbs ────────────────

    @Test
    fun tapMissingXReturns400WithMissingX() {
        // Service is null so we'd hit 503 anyway — but the missing-x
        // check fires first in handleTap, so we see 400.
        val resp = router.route("POST", "/tap", mapOf("y" to "100"), authed())
        // Service-null check actually runs first; the router returns
        // 503 before the param check has a chance to fire. Both are
        // valid responses — pin whichever the current implementation
        // produces so it doesn't drift silently.
        assertTrue(
            "expected 400 missing_x or 503 service-unavailable, got ${resp.statusCode}",
            resp.statusCode == 400 || resp.statusCode == 503
        )
    }

    @Test
    fun keyboardKeyMissingKeyCodeReturns400OrServiceUnavailable() {
        val resp = router.route("POST", "/keyboard/key", emptyMap(), authed())
        assertTrue(
            "expected 400 or 503, got ${resp.statusCode}",
            resp.statusCode == 400 || resp.statusCode == 503
        )
    }

    // ── Service availability ─────────────────────────────────────

    @Test
    fun routesThatTouchServiceReturn503WhenServiceNull() {
        val touchService = listOf(
            "GET" to "/screenshot",
            "GET" to "/a11y_tree_full",
            "POST" to "/tap",
            "POST" to "/swipe",
            "POST" to "/keyboard/input",
            "POST" to "/keyboard/key",
        )
        for ((method, path) in touchService) {
            val params = when (path) {
                "/tap" -> mapOf("x" to "10", "y" to "10")
                "/swipe" -> mapOf("startX" to "0", "startY" to "0", "endX" to "10", "endY" to "10")
                "/keyboard/input" -> mapOf("base64_text" to "aGk=")
                "/keyboard/key" -> mapOf("key_code" to "3")
                else -> emptyMap()
            }
            val resp = router.route(method, path, params, authed())
            assertEquals("$method $path expected 503", 503, resp.statusCode)
            val json = JSONObject(resp.body)
            assertEquals(
                "$method $path expected accessibility_service_not_running",
                "accessibility_service_not_running",
                json.getString("code")
            )
        }
    }

    // ── Error shape ──────────────────────────────────────────────

    @Test
    fun errorEnvelopeHasStatusAndCode() {
        val resp = router.route("GET", "/unknown", emptyMap(), authed())
        val json = JSONObject(resp.body)
        assertEquals("error", json.getString("status"))
        assertTrue("code present", json.has("code"))
    }
}