// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge.handler

import android.accessibilityservice.AccessibilityService
import android.graphics.Bitmap
import android.util.Base64
import android.view.Display
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Captures screenshots via `AccessibilityService.takeScreenshot()` and
 * returns a base64-encoded PNG (NO_WRAP, single line) ready for the
 * wire envelope.
 *
 * Replicates csat's `CaptureHandler`. Pre-API-30 fallback (manual
 * `screencap` via shell) is intentionally absent — `minSdk=30` in our
 * Gradle config already matches the API 30+ requirement of
 * `AccessibilityService.takeScreenshot`, so no installable device
 * needs the fallback.
 *
 * Memory profile: `hwBitmap.copy(ARGB_8888, false)` allocates
 * `width × height × 4` bytes (≈10 MB on 1080×2400, 40+ MB on tablets
 * / foldables). `Bitmap.compress(PNG, …)` allocates more for the
 * encoded form. `PixelCopy` is NOT a viable alternative here —
 * `AccessibilityService` has no `Window` reference to drive PixelCopy
 * from, and `takeScreenshot` is the framework's documented capture
 * path for a11y services. The copy from HARDWARE to ARGB_8888 is
 * required because `Bitmap.compress` doesn't operate on
 * HARDWARE-config bitmaps. We catch `OutOfMemoryError` from the copy
 * so a transient OOM degrades to `screenshot_failed` instead of
 * crashing the bridge.
 */
class CaptureHandler {

    fun capture(service: AccessibilityService): String? {
        val latch = CountDownLatch(1)
        val bitmapRef = AtomicReference<Bitmap?>(null)
        val timedOut = AtomicReference(false)

        service.takeScreenshot(
            Display.DEFAULT_DISPLAY,
            service.mainExecutor,
            object : AccessibilityService.TakeScreenshotCallback {
                override fun onSuccess(result: AccessibilityService.ScreenshotResult) {
                    val hwBitmap = Bitmap.wrapHardwareBuffer(result.hardwareBuffer, result.colorSpace)
                    val copied = try {
                        hwBitmap?.copy(Bitmap.Config.ARGB_8888, false)
                    } catch (_: OutOfMemoryError) {
                        // 40+ MB allocation can OOM on memory-pressured
                        // devices (tablet + multitasking + low-spec). Return
                        // null so capture() degrades to `screenshot_failed`
                        // rather than crashing the bridge.
                        null
                    }
                    hwBitmap?.recycle()
                    result.hardwareBuffer.close()
                    // Sequence matters: set bitmapRef FIRST, then check
                    // timedOut. The caller does the inverse — set timedOut
                    // first, then drain bitmapRef. Either path arrives at
                    // "exactly one of them holds the bitmap and recycles
                    // it" without races. Without these two-step CASes a
                    // bitmap set after the await timed out would leak.
                    if (copied != null) {
                        bitmapRef.set(copied)
                        if (timedOut.get()) {
                            bitmapRef.getAndSet(null)?.recycle()
                        }
                    }
                    latch.countDown()
                }

                override fun onFailure(errorCode: Int) {
                    latch.countDown()
                }
            },
        )

        if (!latch.await(SCREENSHOT_TIMEOUT_SEC, TimeUnit.SECONDS)) {
            timedOut.set(true)
            // Drain whatever the callback may have set between
            // `latch.await` returning false and `timedOut.set(true)`
            // landing. `getAndSet(null)` is the atomic counterpart
            // to the callback's `set`-then-check-timedOut dance.
            bitmapRef.getAndSet(null)?.recycle()
            return null
        }

        return bitmapRef.get()?.let { bmp ->
            val stream = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.PNG, PNG_QUALITY, stream)
            bmp.recycle()
            Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
        }
    }

    companion object {
        private const val SCREENSHOT_TIMEOUT_SEC = 5L
        private const val PNG_QUALITY = 100
    }
}