// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge.handler

import android.accessibilityservice.AccessibilityService
import android.os.Bundle
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Text input + key-event dispatch.
 *
 * Replicates csat's `InputHandler` minus the custom-IME fallback (per
 * our Q5: sim-use ships no IME — `ACTION_SET_TEXT` on the focused node
 * is the only supported text path, and `/keyboard/key` accepts only
 * HOME/BACK/RECENTS).
 *
 * `calculateInputText` is verbatim from csat — it handles the case
 * where the platform reports the hint as `text` on an empty EditText.
 */
class InputHandler {

    fun inputText(
        root: AccessibilityNodeInfo?,
        text: String,
        clear: Boolean,
    ): Boolean {
        val focused = root?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        try {
            val newText = calculateInputText(
                currentText = focused.text?.toString(),
                hintText = focused.hintText?.toString(),
                newText = text,
                clear = clear,
            )
            val args = Bundle().apply {
                putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    newText,
                )
            }
            val ok = focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            if (ok) {
                // `ACTION_SET_TEXT` silently resets caret/selection to
                // position 0. For append-mode (`clear=false`) that's
                // surprising — the caller types "abc" expecting the
                // caret at the end of "<existing>abc", but it lands
                // at the start. Follow with `ACTION_SET_SELECTION`
                // pointing to the end of the new text so the caret
                // matches a human's "type at end" intuition. Failures
                // are non-fatal (some custom EditText subclasses
                // reject the action) — the text was already written.
                val length = newText.length
                val selArgs = Bundle().apply {
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, length)
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, length)
                }
                @Suppress("UNUSED_VARIABLE")
                val moved = focused.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, selArgs)
            }
            return ok
        } finally {
            @Suppress("DEPRECATION")
            try { focused.recycle() } catch (_: Exception) {}
        }
    }

    /**
     * Returns one of:
     *   - `KeyResult.Performed` — global action dispatched successfully
     *   - `KeyResult.Unsupported` — keycode not one of HOME/BACK/RECENTS/POWER
     *   - `KeyResult.Failed` — keycode is allowed but `performGlobalAction` returned false
     *
     * Per our wire spec, unsupported keycodes are NOT silently broadcast
     * through a custom IME (csat does this); they're a structured 400
     * error pointing the caller at `/keyboard/input`.
     *
     * `KEYCODE_POWER` maps to `GLOBAL_ACTION_LOCK_SCREEN` (API 28+, fine
     * given minSdk=30). It's the Android analogue of iOS's lock button:
     * locks the device / turns the screen off.
     */
    fun keyEvent(service: AccessibilityService, keyCode: Int): KeyResult =
        when (keyCode) {
            KEYCODE_HOME -> if (service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_HOME)) KeyResult.Performed else KeyResult.Failed
            KEYCODE_BACK -> if (service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)) KeyResult.Performed else KeyResult.Failed
            KEYCODE_RECENTS -> if (service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_RECENTS)) KeyResult.Performed else KeyResult.Failed
            KEYCODE_POWER -> if (service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN)) KeyResult.Performed else KeyResult.Failed
            else -> KeyResult.Unsupported
        }

    enum class KeyResult { Performed, Unsupported, Failed }

    companion object {
        const val KEYCODE_HOME = 3
        const val KEYCODE_BACK = 4
        const val KEYCODE_POWER = 26
        const val KEYCODE_RECENTS = 187

        /**
         * Build the final text for ACTION_SET_TEXT.
         * When the field only shows placeholder (hintText == currentText),
         * treat it as empty so the placeholder isn't prepended.
         *
         * Borrowed verbatim from csat — solves a real-world quirk where
         * Android reports the hint string as `text` on empty inputs.
         */
        fun calculateInputText(
            currentText: String?,
            hintText: String?,
            newText: String,
            clear: Boolean,
        ): String {
            if (clear) return newText
            val current = currentText.orEmpty()
            if (!hintText.isNullOrEmpty() && current == hintText) return newText
            return current + newText
        }
    }
}