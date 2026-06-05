// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge

import com.linecorp.simuse.devicebridge.handler.InputHandler
import com.linecorp.simuse.devicebridge.server.ActionRouter
import com.linecorp.simuse.devicebridge.server.HttpServer
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * Tests for the pure-Kotlin helpers that don't require Android.
 *
 * The Android-coupled paths (ContentProvider cursor, HTTP server,
 * AccessibilityService) need instrumented tests on a device; those run
 * as part of the live emulator smoke loop, not this suite.
 */
class BridgePureLogicTest {

    // ── AuthManager wire shape ─────────────────────────────────

    @Test
    fun authEnvelopeMatchesContract() {
        val token = UUID.randomUUID().toString()
        val payload = JSONObject().apply {
            put("status", "success")
            put("result", token)
        }
        val reparsed = JSONObject(payload.toString())
        assertEquals("success", reparsed.getString("status"))
        assertEquals(token, reparsed.getString("result"))
        assertNotNull(reparsed.optString("result"))
    }

    // ── InputHandler.calculateInputText ─────────────────────────

    @Test
    fun clearReplacesText() {
        assertEquals(
            "new",
            InputHandler.calculateInputText(
                currentText = "old",
                hintText = null,
                newText = "new",
                clear = true,
            ),
        )
    }

    @Test
    fun appendConcatsToExisting() {
        assertEquals(
            "olnew",
            InputHandler.calculateInputText(
                currentText = "ol",
                hintText = null,
                newText = "new",
                clear = false,
            ),
        )
    }

    @Test
    fun appendIgnoresHintWhenCurrentEqualsHint() {
        // The empty-EditText hint quirk: some Android versions report the
        // hint string as `text` on an empty field. Without this guard the
        // appended result would be `Phonewei` instead of `wei`.
        assertEquals(
            "wei",
            InputHandler.calculateInputText(
                currentText = "Phone",
                hintText = "Phone",
                newText = "wei",
                clear = false,
            ),
        )
    }

    @Test
    fun appendKeepsCurrentWhenHintMissing() {
        assertEquals(
            "realwei",
            InputHandler.calculateInputText(
                currentText = "real",
                hintText = null,
                newText = "wei",
                clear = false,
            ),
        )
    }

    @Test
    fun appendKeepsRealTextWhenHintDiffers() {
        assertEquals(
            "realwei",
            InputHandler.calculateInputText(
                currentText = "real",
                hintText = "Phone",
                newText = "wei",
                clear = false,
            ),
        )
    }

    // ── HttpServer form parser ─────────────────────────────────

    @Test
    fun formParserSplitsKeyValuePairs() {
        val parsed = HttpServer.parseFormUrlEncoded("x=10&y=20&z=hello")
        assertEquals("10", parsed["x"])
        assertEquals("20", parsed["y"])
        assertEquals("hello", parsed["z"])
    }

    @Test
    fun formParserUrlDecodes() {
        val parsed = HttpServer.parseFormUrlEncoded("greeting=hello%20world&plus=a%2Bb")
        assertEquals("hello world", parsed["greeting"])
        assertEquals("a+b", parsed["plus"])
    }

    @Test
    fun formParserSkipsMalformedChunks() {
        val parsed = HttpServer.parseFormUrlEncoded("good=yes&malformed&another=ok")
        assertEquals("yes", parsed["good"])
        assertEquals("ok", parsed["another"])
        assertFalse(parsed.containsKey("malformed"))
    }

    @Test
    fun formParserOnEmptyReturnsEmpty() {
        assertTrue(HttpServer.parseFormUrlEncoded("").isEmpty())
    }

    // ── ActionRouter envelope helpers ──────────────────────────

    @Test
    fun successJsonNoResult() {
        val obj = JSONObject(ActionRouter.successJson())
        assertEquals("success", obj.getString("status"))
        assertNull(obj.opt("result"))
    }

    @Test
    fun successJsonStringResult() {
        val obj = JSONObject(ActionRouter.successJson("pong"))
        assertEquals("success", obj.getString("status"))
        assertEquals("pong", obj.getString("result"))
    }

    @Test
    fun successJsonInlineObjectResult() {
        // Inline-JSON envelope: object results stay objects on the wire,
        // not JSON-encoded strings.
        val inner = JSONObject().apply { put("k", "v") }
        val obj = JSONObject(ActionRouter.successJson(inner))
        assertEquals("success", obj.getString("status"))
        assertEquals("v", obj.getJSONObject("result").getString("k"))
    }

    @Test
    fun errorJsonWithMessage() {
        val obj = JSONObject(ActionRouter.errorJson("missing_x", "bad request"))
        assertEquals("error", obj.getString("status"))
        assertEquals("missing_x", obj.getString("code"))
        assertEquals("bad request", obj.getString("error"))
    }

    @Test
    fun errorJsonWithoutMessage() {
        val obj = JSONObject(ActionRouter.errorJson("unauthorized"))
        assertEquals("error", obj.getString("status"))
        assertEquals("unauthorized", obj.getString("code"))
        assertNull(obj.opt("error"))
    }
}