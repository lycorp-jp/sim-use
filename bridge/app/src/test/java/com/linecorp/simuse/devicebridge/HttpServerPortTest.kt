// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge

import com.linecorp.simuse.devicebridge.server.HttpServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.BindException

class HttpServerPortTest {
    @Test fun preferredPortIsUsed() {
        val preferred = HttpServer.bindAvailablePort(listOf(0)).use { it.localPort }
        HttpServer.bindAvailablePort(listOf(preferred, 0)).use { socket ->
            assertEquals(preferred, socket.localPort)
            assertTrue(socket.inetAddress.isLoopbackAddress)
        }
    }

    @Test fun occupiedPreferredPortUsesFallback() {
        HttpServer.bindAvailablePort(listOf(0)).use { occupied ->
            HttpServer.bindAvailablePort(listOf(occupied.localPort, 0)).use { fallback ->
                assertTrue(fallback.localPort != occupied.localPort)
            }
        }
    }

    @Test fun allOccupiedPortsGiveActionableError() {
        HttpServer.bindAvailablePort(listOf(0)).use { occupied ->
            try {
                HttpServer.bindAvailablePort(listOf(occupied.localPort)).close()
                throw AssertionError("Expected bind failure")
            } catch (e: BindException) {
                assertTrue(e.message!!.contains("ports are occupied"))
                assertTrue(e.message!!.contains(occupied.localPort.toString()))
                assertTrue(e.message!!.contains("ss -ltnp"))
            }
        }
    }
}
