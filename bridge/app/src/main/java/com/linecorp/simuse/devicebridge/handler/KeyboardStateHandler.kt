// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge.handler

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityWindowInfo

/**
 * Reports whether a software IME is currently visible on the display, by
 * walking `AccessibilityService.windows` for a window of type
 * `TYPE_INPUT_METHOD`.
 *
 * Requires `flagRetrieveInteractiveWindows` in the accessibility service
 * config — without it `service.windows` always returns an empty list.
 *
 * Output (consumed by ActionRouter): `(visible, imePackage?)`. `imePackage`
 * is the package name of the IME (e.g. `com.google.android.inputmethod.latin`)
 * when discoverable; `null` if the window has no root we can inspect.
 */
class KeyboardStateHandler {

    data class State(val visible: Boolean, val imePackage: String?)

    fun query(service: AccessibilityService): State {
        val windows = service.windows ?: return State(visible = false, imePackage = null)
        val imeWindow = windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            ?: return State(visible = false, imePackage = null)
        val root = imeWindow.root
        val pkg = root?.packageName?.toString()
        @Suppress("DEPRECATION")
        try { root?.recycle() } catch (_: Exception) {}
        return State(visible = true, imePackage = pkg)
    }
}