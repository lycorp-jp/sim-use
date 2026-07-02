// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge

import com.linecorp.simuse.devicebridge.handler.GestureHandler
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * `/swipe` duration clamp contract. The Swift client validates
 * `--duration` up to 10 s (long-press taps and holds are delivered as
 * `/swipe` with start == end), so the bridge must accept the full
 * client range instead of silently shortening a 10 s hold to 5 s.
 * Android's GestureDescription supports strokes well beyond 10 s, so
 * the ceiling exists only to bound runaway requests.
 */
class GestureHandlerClampTest {

    @Test
    fun clampKeepsClientRangeIntact() {
        // Client contract allows up to 10s — must pass through unchanged.
        assertEquals(7_000L, GestureHandler.clampSwipeDuration(7_000L))
        assertEquals(10_000L, GestureHandler.clampSwipeDuration(10_000L))
    }

    @Test
    fun clampBoundsRunawayValues() {
        assertEquals(10_000L, GestureHandler.clampSwipeDuration(60_000L))
        assertEquals(10L, GestureHandler.clampSwipeDuration(0L))
        assertEquals(10L, GestureHandler.clampSwipeDuration(-5L))
    }
}
