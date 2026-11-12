// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge

import com.linecorp.simuse.devicebridge.config.AuthManager
import com.linecorp.simuse.devicebridge.server.ActionRouter
import com.linecorp.simuse.devicebridge.server.HttpServer
import com.linecorp.simuse.devicebridge.service.SimuseAccessibilityService
import io.mockk.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class EndpointSnapshotTest {
    @Before fun setup() {
        mockkConstructor(AuthManager::class)
        mockkConstructor(ActionRouter::class)
        mockkConstructor(HttpServer::class)
        every { anyConstructed<ActionRouter>().close() } just Runs
        every { anyConstructed<HttpServer>().isRunning } returns false
        every { anyConstructed<HttpServer>().boundPort } returns 49153
        every { anyConstructed<HttpServer>().stop() } just Runs
    }

    @After fun cleanup() = unmockkAll()

    private fun snapshot(service: SimuseAccessibilityService): Triple<Int?, String?, String> {
        val value = service.endpointSnapshot()
        return Triple(value.port, value.error, value.state)
    }

    @Test fun snapshotWaitsForConcurrentStartAndStop() {
        for (starting in listOf(true, false)) {
            val service = SimuseAccessibilityService()
            every { anyConstructed<HttpServer>().start() } just Runs
            if (!starting) service.startServer()
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            val reading = CountDownLatch(1)
            val pool = Executors.newFixedThreadPool(2)
            try {
                if (starting) every { anyConstructed<HttpServer>().start() } answers {
                    entered.countDown()
                    check(release.await(5, TimeUnit.SECONDS))
                } else every { anyConstructed<HttpServer>().stop() } answers {
                    entered.countDown()
                    check(release.await(5, TimeUnit.SECONDS))
                }
                val transition = pool.submit { if (starting) service.startServer() else service.stopServer() }
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                val query = pool.submit<Triple<Int?, String?, String>> {
                    reading.countDown()
                    snapshot(service)
                }
                assertTrue(reading.await(5, TimeUnit.SECONDS))
                // Query cannot publish an intermediate snapshot while the transition owns the monitor.
                try {
                    query.get(100, TimeUnit.MILLISECONDS)
                    fail("Snapshot completed during transition")
                } catch (_: java.util.concurrent.TimeoutException) {}
                release.countDown()
                transition.get(5, TimeUnit.SECONDS)
                assertEquals(if (starting) Triple(49153, null, "running") else Triple(null, null, "stopped"),
                    query.get(5, TimeUnit.SECONDS))
            } finally {
                release.countDown()
                pool.shutdownNow()
            }
        }
    }

    @Test fun failedBindCanRestart() {
        val service = SimuseAccessibilityService()
        var listener: java.net.ServerSocket? = null
        var failBind = true
        every { anyConstructed<HttpServer>().start() } answers {
            if (failBind) throw java.net.BindException("Test bind failure")
            listener = HttpServer.bindAvailablePort(0)
        }
        every { anyConstructed<HttpServer>().boundPort } answers { listener?.localPort }
        every { anyConstructed<HttpServer>().stop() } answers { listener?.close(); Unit }
        try {
            service.startServer()
            val failed = snapshot(service)
            assertNull(failed.first)
            assertEquals("Test bind failure", failed.second)
            assertEquals("failed", failed.third)
            failBind = false
            service.startServer()
            assertEquals(Triple(listener!!.localPort, null, "running"), snapshot(service))
            service.stopServer()
            assertEquals(Triple(null, null, "stopped"), snapshot(service))
        } finally {
            listener?.close()
        }
    }
}
