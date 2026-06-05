// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge.service

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Binder
import android.os.Process
import com.linecorp.simuse.devicebridge.config.AuthManager
import org.json.JSONObject

/**
 * Surfaces auth-token retrieval and server-toggle to `adb shell content
 * query / insert` so `sim-use android init` can bootstrap without an
 * Activity.
 *
 * URIs:
 *   - `content://com.linecorp.simuse.devicebridge/auth_token`         query
 *   - `content://com.linecorp.simuse.devicebridge/toggle_socket_server` insert with `enabled:b:true|false`
 *
 * Same shape and same query-cursor encoding as csat's
 * `CsatContentProvider`. The returned token row format
 * (`result={"status":"success","result":"<uuid>"}`) is what the Swift
 * `AuthTokenFetcher` already expects, so no client change is needed.
 *
 * Access is gated to `adb shell` / root only by [assertShellCaller]. The
 * provider is `exported="true"` in the manifest because adb-shell calls
 * arrive as cross-process IPC; signature-permission would also block adb
 * shell (the shell UID does not share our app signature). The UID check
 * is what keeps installed apps from harvesting the bearer token.
 */
class SimuseContentProvider : ContentProvider() {

    private val authManager by lazy { AuthManager(context!!) }

    override fun onCreate(): Boolean = true

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? {
        assertShellCaller()
        if (uri.lastPathSegment != PATH_AUTH_TOKEN) return null
        val token = authManager.getOrCreateToken()
        val json = JSONObject().apply {
            put("status", "success")
            put("result", token)
        }.toString()
        return MatrixCursor(arrayOf(COLUMN_RESULT)).apply {
            addRow(arrayOf(json))
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? {
        assertShellCaller()
        if (uri.lastPathSegment != PATH_TOGGLE_SERVER) return null
        val enabled = values?.getAsBoolean("enabled") ?: true
        val service = SimuseAccessibilityService.instance
        if (enabled) service?.startServer() else service?.stopServer()
        return uri
    }

    override fun getType(uri: Uri): String? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0

    /**
     * Rejects any caller other than `adb shell` (UID 2000) or root (UID 0).
     * Without this guard, any installed app can `ContentResolver.query` the
     * auth_token URI and obtain the bearer token used to talk to the
     * on-device HTTP bridge.
     */
    private fun assertShellCaller() {
        val uid = Binder.getCallingUid()
        if (uid != Process.SHELL_UID && uid != Process.ROOT_UID) {
            throw SecurityException(
                "SimuseContentProvider is reachable only from adb shell (uid=$uid)"
            )
        }
    }

    companion object {
        private const val PATH_AUTH_TOKEN = "auth_token"
        private const val PATH_TOGGLE_SERVER = "toggle_socket_server"
        private const val COLUMN_RESULT = "result"
    }
}