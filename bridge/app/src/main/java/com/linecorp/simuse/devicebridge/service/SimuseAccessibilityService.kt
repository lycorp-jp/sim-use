// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge.service

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import com.linecorp.simuse.devicebridge.config.AuthManager
import com.linecorp.simuse.devicebridge.server.ActionRouter
import com.linecorp.simuse.devicebridge.server.HttpServer

/**
 * sim-use bridge accessibility service.
 *
 * Owns:
 *   - the HTTP server lifecycle (started on `onServiceConnected`,
 *     stopped on `onUnbind` / `onDestroy`)
 *   - the foreground keep-alive child service that prevents Samsung et
 *     al from killing the process
 *   - a static `instance` reference so the ContentProvider can start /
 *     stop the server without an Activity
 *
 * Direct copy of csat's `CsatAccessibilityService` shape, just renamed.
 */
class SimuseAccessibilityService : AccessibilityService() {

    // `@Volatile` so writes from `onServiceConnected` / `onUnbind`
    // are immediately visible to ContentProvider callers (which
    // dereference `instance.startServer()` / `.stopServer()` from
    // arbitrary Binder threads). Without volatile a stale-cached
    // `httpServer` reference could survive a stop-then-start
    // cycle on the wrong thread.
    @Volatile
    private var httpServer: HttpServer? = null
    @Volatile
    private var router: ActionRouter? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        startServer()
        startKeepAliveService()
        Log.i(TAG, "onServiceConnected (pid=${android.os.Process.myPid()})")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // No event-driven state. We pull rootInActiveWindow on demand.
    }

    override fun onInterrupt() {
        Log.w(TAG, "onInterrupt")
    }

    override fun onUnbind(intent: Intent?): Boolean {
        Log.w(TAG, "onUnbind (pid=${android.os.Process.myPid()})")
        stopServer()
        stopKeepAliveService()
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        Log.w(TAG, "onDestroy (pid=${android.os.Process.myPid()})")
        stopServer()
        instance = null
        super.onDestroy()
    }

    @Synchronized
    fun startServer() {
        if (httpServer?.isRunning == true) return
        val authManager = AuthManager(this)
        val newRouter = ActionRouter(
            serviceProvider = { instance },
            authManager = authManager,
        )
        router = newRouter
        startupError = null
        try {
            httpServer = HttpServer(SERVER_PORT, newRouter).also { it.start() }
            Log.i(TAG, "HTTP server started on port $serverPort")
        } catch (e: Exception) {
            newRouter.close()
            router = null
            startupError = e.message ?: "Bridge server could not start"
            Log.e(TAG, startupError, e)
        }
    }

    @Synchronized
    fun stopServer() {
        startupError = null
        httpServer?.stop()
        httpServer = null
        // Shut down the router's `rootWindowExecutor` (cached
        // thread pool) so service-unbind doesn't leave a forest
        // of "AwaitedTreeWorker" threads against a dead service
        // instance. Done after `httpServer.stop()` so any in-
        // flight handlers have already returned.
        router?.close()
        router = null
        Log.i(TAG, "HTTP server stopped")
    }

    @Volatile
    var startupError: String? = null
        private set
    val serverPort: Int? get() = endpointSnapshot().port

    data class EndpointSnapshot(val port: Int?, val error: String?, val state: String)

    // Use the start/stop monitor: discovery waits until a transition completes.
    @Synchronized
    fun endpointSnapshot(): EndpointSnapshot {
        val port = httpServer?.boundPort
        val error = startupError
        return EndpointSnapshot(port, error, when {
            port != null -> "running"
            error != null -> "failed"
            else -> "stopped"
        })
    }

    val isServerRunning: Boolean get() = httpServer?.isRunning == true

    private fun startKeepAliveService() {
        try {
            val intent = Intent(this, BridgeKeepAliveService::class.java)
            startForegroundService(intent)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to start keep-alive service: ${e.message}")
        }
    }

    private fun stopKeepAliveService() {
        try {
            stopService(Intent(this, BridgeKeepAliveService::class.java))
        } catch (e: Exception) {
            Log.w(TAG, "Failed to stop keep-alive service: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "SimuseA11yService"
        const val SERVER_PORT = 8080

        @Volatile
        var instance: SimuseAccessibilityService? = null
            private set
    }
}