// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge.handler

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.util.Log
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Sets the device clipboard to the supplied text and triggers a paste on
 * the currently focused input field via `ACTION_PASTE`.
 *
 * Mirrors the iOS `sim-use paste` semantics: place text on the system
 * pasteboard and let the focused field consume it, bypassing the soft
 * keyboard / IME composition entirely. Unlike `ACTION_SET_TEXT` (used by
 * `inputText`), this triggers the field's paste handler, so listeners
 * that distinguish typed vs pasted input see the paste event.
 *
 * `replace=true` selects the field's current contents before pasting by
 * walking `ACTION_SET_SELECTION` from start to end. The selection action
 * causes ACTION_PASTE to overwrite the selection rather than insert at
 * caret (mirrors iOS's Cmd+A + Cmd+V combo).
 *
 * Failure modes:
 *  - `Result.NoFocusedInput` — no field has accessibility focus.
 *  - `Result.PasteUnsupported` — focused field doesn't expose ACTION_PASTE
 *    (rare; some custom views).
 *  - `Result.ClipboardWriteFailed` — `setPrimaryClip` threw / silently no-op'd.
 *    On Android 10+ background services may be denied clipboard write by
 *    the platform; on the emulator we typically have permission.
 */
class PasteHandler {

    enum class Result { Ok, NoFocusedInput, PasteUnsupported, ClipboardWriteFailed }

    fun paste(
        service: Context,
        root: AccessibilityNodeInfo?,
        text: String,
        replace: Boolean,
    ): Result {
        val clipboard = service.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return Result.ClipboardWriteFailed
        try {
            clipboard.setPrimaryClip(ClipData.newPlainText(CLIP_LABEL, text))
        } catch (e: SecurityException) {
            Log.w(TAG, "setPrimaryClip denied: ${e.message}")
            return Result.ClipboardWriteFailed
        }
        // Read back the clipboard and verify the write actually
        // landed. On Android 10+ background processes are
        // increasingly denied `setPrimaryClip` silently — the call
        // returns without throwing but the clipboard contents stay
        // unchanged. Without this verification the subsequent
        // `ACTION_PASTE` would paste whatever was on the clipboard
        // before, surprising the agent. The verification reads the
        // first item's text via `coerceToText` so HTML / styled-
        // text clipboards (rare for sim-use callers — text is
        // always coming from `setPrimaryClip(newPlainText)`) still
        // round-trip cleanly.
        val written = try {
            clipboard.primaryClip?.getItemAt(0)?.coerceToText(service)?.toString()
        } catch (_: Exception) { null }
        if (written != text) {
            Log.w(TAG, "setPrimaryClip silently no-op'd (wrote ${text.length} chars, read back ${written?.length ?: -1}); background-restricted device?")
            return Result.ClipboardWriteFailed
        }

        val focused = root?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return Result.NoFocusedInput
        try {
            if (replace) {
                val existing = focused.text?.toString().orEmpty()
                if (existing.isNotEmpty()) {
                    val args = Bundle().apply {
                        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, existing.length)
                    }
                    focused.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, args)
                }
            }
            val pasted = focused.performAction(AccessibilityNodeInfo.ACTION_PASTE)
            return if (pasted) Result.Ok else Result.PasteUnsupported
        } finally {
            @Suppress("DEPRECATION")
            try { focused.recycle() } catch (_: Exception) {}
        }
    }

    companion object {
        private const val TAG = "SimusePaste"
        private const val CLIP_LABEL = "sim-use"
    }
}