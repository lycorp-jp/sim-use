// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Log

/**
 * Foreground service that keeps the bridge process alive.
 *
 * Background: without a foreground notification, the OS — especially
 * Samsung One UI — aggressively kills accessibility service processes,
 * causing them to unbind and eventually become disabled. Raising the
 * process to FOREGROUND_SERVICE priority via this stub blocks that
 * behavior.
 *
 * Lifted verbatim from csat's `BridgeKeepAliveService` (csat learned
 * this the hard way on real devices); only renamed.
 */
class BridgeKeepAliveService : Service() {

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(
            NOTIFICATION_ID,
            buildNotification(),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
        )
        Log.i(TAG, "Keep-alive foreground service started")
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        Log.i(TAG, "Keep-alive foreground service destroyed")
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "sim-use bridge",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps sim-use accessibility service alive"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification =
        Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("sim-use bridge")
            .setContentText("Accessibility service active")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()

    companion object {
        private const val TAG = "SimuseKeepAlive"
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "sim_use_bridge_keepalive"
    }
}