// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge.config

import android.content.Context
import java.util.UUID

/**
 * Manages the bearer auth token used by HTTP API consumers.
 *
 * Token is generated once on first request and persisted in
 * SharedPreferences. Rotates only on `pm clear`; `sim-use android init`
 * refetches on every connect so rotation is transparent to users.
 *
 * Mirrors csat's `AuthManager` — same shape, just renamed to our
 * package. Deviations from csat are unchanged (SharedPreferences key
 * stays the same to allow easy comparison during debug).
 */
class AuthManager(context: Context) {

    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    @Synchronized
    fun getOrCreateToken(): String {
        val existing = prefs.getString(KEY_TOKEN, null)
        if (existing != null) return existing
        val token = UUID.randomUUID().toString()
        prefs.edit().putString(KEY_TOKEN, token).apply()
        return token
    }

    companion object {
        private const val PREFS_NAME = "sim_use_device_bridge"
        private const val KEY_TOKEN = "auth_token"
    }
}