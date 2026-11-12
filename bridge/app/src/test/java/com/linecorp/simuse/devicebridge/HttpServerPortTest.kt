// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge

import com.linecorp.simuse.devicebridge.server.HttpServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HttpServerPortTest {
    @Test fun preferredPortIsUsed() {
        val preferred = HttpServer.bindAvailablePort(0).use { it.localPort }
        HttpServer.bindAvailablePort(preferred).use { socket ->
            assertEquals(preferred, socket.localPort)
            assertTrue(socket.inetAddress.isLoopbackAddress)
        }
    }

    @Test fun occupiedPreferredPortUsesFallback() {
        HttpServer.bindAvailablePort(0).use { occupied ->
            HttpServer.bindAvailablePort(occupied.localPort).use { fallback ->
                assertTrue(fallback.localPort != occupied.localPort)
                assertTrue(fallback.localPort in 1..65535)
                assertTrue(fallback.inetAddress.isLoopbackAddress)
            }
        }
    }

    @Test fun ephemeralPortIsPublishedInsteadOfZero() {
        HttpServer.bindAvailablePort(0).use { socket ->
            assertTrue(socket.localPort in 1..65535)
            assertTrue(socket.inetAddress.isLoopbackAddress)
        }
    }
}
