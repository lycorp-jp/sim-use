// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge

import android.accessibilityservice.AccessibilityService
import android.util.Base64
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import com.linecorp.simuse.devicebridge.config.AuthManager
import com.linecorp.simuse.devicebridge.server.ActionRouter
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import io.mockk.verify
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/**
 * AccessibilityNodeInfo lifecycle contracts on the router paths that
 * borrow the active-window root:
 *
 *  - `/a11y_tree_full` must read everything it needs from the root
 *    (notably `windowId` for the secondary-window merge) BEFORE
 *    `TreeHandler.buildTree` recycles it. On API 30-32 a recycled
 *    node's fields are cleared, so a post-recycle `windowId` read
 *    silently drops every popup/dialog window from the tree.
 *  - `/keyboard/input` owns the root it borrows and must recycle it
 *    exactly like `/paste` does; `InputHandler` only recycles the
 *    focused child it finds.
 *
 * The recycled-root mock throws on post-recycle field access, which is
 * stricter than API 30-32 (cleared fields) — either behaviour is a bug
 * we want to fail loudly here.
 */
class ActionRouterNodeLifecycleTest {

    private val token = "test-token-1234"
    private lateinit var authManager: AuthManager
    private lateinit var service: AccessibilityService

    @Before
    fun setUp() {
        authManager = mockk()
        every { authManager.getOrCreateToken() } returns token
        service = mockk(relaxed = true)
        every { service.windows } returns emptyList()
        // Relaxed getSystemService returns a plain Object; computeDisplay
        // casts it to WindowManager, so stub a typed mock explicitly.
        every { service.getSystemService(any()) } returns mockk<WindowManager>(relaxed = true)
    }

    @After
    fun tearDown() {
        unmockkStatic(Base64::class)
    }

    private fun authed(): Map<String, String> = mapOf("authorization" to "Bearer $token")

    private fun makeLifecycleTrackedRoot(windowId: Int): Pair<AccessibilityNodeInfo, () -> Boolean> {
        var recycled = false
        val root = mockk<AccessibilityNodeInfo>(relaxed = true)
        every { root.recycle() } answers { recycled = true }
        every { root.childCount } returns 0
        every { root.windowId } answers {
            check(!recycled) { "windowId read after recycle()" }
            windowId
        }
        return root to { recycled }
    }

    @Test
    fun treeHandlerReadsWindowIdBeforeRootIsRecycled() {
        val (root, _) = makeLifecycleTrackedRoot(windowId = 42)
        every { service.rootInActiveWindow } returns root
        val router = ActionRouter(serviceProvider = { service }, authManager = authManager)

        val resp = router.route("GET", "/a11y_tree_full", emptyMap(), authed())

        assertEquals(
            "windowId must be captured before buildTree recycles the root; body=${resp.body}",
            200,
            resp.statusCode,
        )
        assertEquals("success", JSONObject(resp.body).getString("status"))
    }

    @Test
    fun inputHandlerRouteRecyclesBorrowedRoot() {
        // android.util.Base64 is an SDK stub on the JVM (returns null),
        // so bridge it to java.util.Base64 for a real decode.
        mockkStatic(Base64::class)
        every { Base64.decode(any<String>(), any()) } answers {
            java.util.Base64.getDecoder().decode(firstArg<String>())
        }

        val (root, wasRecycled) = makeLifecycleTrackedRoot(windowId = 42)
        every { service.rootInActiveWindow } returns root
        val router = ActionRouter(serviceProvider = { service }, authManager = authManager)

        val b64 = java.util.Base64.getEncoder().encodeToString("hello".toByteArray())
        router.route("POST", "/keyboard/input", mapOf("base64_text" to b64), authed())

        verify(exactly = 1) { root.recycle() }
        assertEquals(true, wasRecycled())
    }
}
