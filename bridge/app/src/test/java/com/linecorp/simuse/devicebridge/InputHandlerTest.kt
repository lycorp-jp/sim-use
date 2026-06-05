// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge

import android.accessibilityservice.AccessibilityService
import com.linecorp.simuse.devicebridge.handler.InputHandler
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Locks the per-keycode dispatch contract of `InputHandler.keyEvent`.
 * The bridge intentionally exposes only a small allowlist of system
 * keys; this suite checks each allowed code routes to the right
 * `GLOBAL_ACTION_*` and that everything else returns `Unsupported`
 * (so the wire surfaces `unsupported_keycode` 400 to callers instead
 * of silently dropping the request).
 *
 * Particularly pinning POWER (26) since it's the newest addition and
 * the only mapping that crosses to `GLOBAL_ACTION_LOCK_SCREEN` — easy
 * to regress if someone moves the `when` arms around.
 */
class InputHandlerTest {

    private val handler = InputHandler()

    @Test
    fun keyEventHomeRoutesToGlobalActionHome() {
        val service = mockk<AccessibilityService>()
        every { service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_HOME) } returns true
        val result = handler.keyEvent(service, InputHandler.KEYCODE_HOME)
        assertEquals(InputHandler.KeyResult.Performed, result)
        verify(exactly = 1) { service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_HOME) }
    }

    @Test
    fun keyEventBackRoutesToGlobalActionBack() {
        val service = mockk<AccessibilityService>()
        every { service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK) } returns true
        val result = handler.keyEvent(service, InputHandler.KEYCODE_BACK)
        assertEquals(InputHandler.KeyResult.Performed, result)
        verify(exactly = 1) { service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK) }
    }

    @Test
    fun keyEventRecentsRoutesToGlobalActionRecents() {
        val service = mockk<AccessibilityService>()
        every { service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_RECENTS) } returns true
        val result = handler.keyEvent(service, InputHandler.KEYCODE_RECENTS)
        assertEquals(InputHandler.KeyResult.Performed, result)
        verify(exactly = 1) { service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_RECENTS) }
    }

    @Test
    fun keyEventPowerRoutesToGlobalActionLockScreen() {
        // POWER → LOCK_SCREEN — the newest addition; cross-platform
        // `sim-use button lock` rides this mapping.
        val service = mockk<AccessibilityService>()
        every { service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN) } returns true
        val result = handler.keyEvent(service, InputHandler.KEYCODE_POWER)
        assertEquals(InputHandler.KeyResult.Performed, result)
        verify(exactly = 1) { service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN) }
    }

    @Test
    fun keyEventReturnsFailedWhenGlobalActionReturnsFalse() {
        val service = mockk<AccessibilityService>()
        every { service.performGlobalAction(any()) } returns false
        val result = handler.keyEvent(service, InputHandler.KEYCODE_HOME)
        assertEquals(InputHandler.KeyResult.Failed, result)
    }

    @Test
    fun keyEventReturnsUnsupportedForUnknownKeycode() {
        // Anything outside HOME/BACK/RECENTS/POWER must NOT silently
        // dispatch — the wire contract is that `/keyboard/key` rejects
        // unsupported keycodes with a 400 (`unsupported_keycode`).
        val service = mockk<AccessibilityService>()
        // No `every {} returns ...` stub here: the test fails (mockk
        // throws MissingMethodCallException) if the handler ever
        // calls performGlobalAction for a non-allowlisted key.
        for (badCode in listOf(29 /* KEYCODE_A */, 66 /* KEYCODE_ENTER */, 67 /* KEYCODE_DEL */, 999)) {
            val result = handler.keyEvent(service, badCode)
            assertEquals("keycode $badCode should be unsupported", InputHandler.KeyResult.Unsupported, result)
        }
    }
}