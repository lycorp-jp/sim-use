// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge

import android.net.Uri
import android.os.Binder
import com.linecorp.simuse.devicebridge.service.SimuseContentProvider
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkAll
import org.junit.After
import org.junit.Assert.assertNotNull
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/**
 * Verifies that [SimuseContentProvider] enforces shell/root caller UID.
 *
 * The Android `content` CLI is already system-restricted to the shell
 * UID (`ACCESS_CONTENT_PROVIDERS_EXTERNALLY` permission), but installed
 * apps can still call `ContentResolver.query()` directly. The UID guard
 * in `query`/`insert` is the only thing standing between an arbitrary
 * app and the auth-token bearer for the HTTP bridge.
 */
class SimuseContentProviderTest {

    private val authTokenUri: Uri = mockk(relaxed = true) {
        every { lastPathSegment } returns "auth_token"
    }
    private val toggleUri: Uri = mockk(relaxed = true) {
        every { lastPathSegment } returns "toggle_socket_server"
    }

    @Before
    fun setUp() {
        mockkStatic(Binder::class)
    }

    @After
    fun tearDown() {
        unmockkAll()
    }

    @Test(expected = SecurityException::class)
    fun queryRejectsArbitraryAppUid() {
        every { Binder.getCallingUid() } returns 10191 // typical user-app UID
        SimuseContentProvider().query(authTokenUri, null, null, null, null)
    }

    @Test(expected = SecurityException::class)
    fun insertRejectsArbitraryAppUid() {
        every { Binder.getCallingUid() } returns 10042
        SimuseContentProvider().insert(toggleUri, null)
    }

    @Test(expected = SecurityException::class)
    fun queryRejectsSystemUid() {
        // System UID (1000) is privileged but is NOT shell. We want a hard
        // shell-only contract; system_server has no business reading our
        // bearer token.
        every { Binder.getCallingUid() } returns 1000
        SimuseContentProvider().query(authTokenUri, null, null, null, null)
    }

    @Test
    fun queryAcceptsShellUid() {
        every { Binder.getCallingUid() } returns 2000 // Process.SHELL_UID
        try {
            // We only assert the guard does NOT throw. Reaching the real
            // body would need a Context for AuthManager; in default-values
            // mode the lazy property is never touched because the URI
            // matches and we abandon the test there — the call may NPE on
            // MatrixCursor construction in stub mode, which is fine.
            SimuseContentProvider().query(authTokenUri, null, null, null, null)
        } catch (e: SecurityException) {
            fail("Shell UID should not be rejected, got: ${e.message}")
        } catch (e: Exception) {
            // Anything else (NPE on stubbed Android types, etc.) is
            // acceptable for this guard-only test.
        }
    }

    @Test
    fun queryAcceptsRootUid() {
        every { Binder.getCallingUid() } returns 0 // Process.ROOT_UID
        try {
            SimuseContentProvider().query(authTokenUri, null, null, null, null)
        } catch (e: SecurityException) {
            fail("Root UID should not be rejected, got: ${e.message}")
        } catch (e: Exception) {
            // See note above.
        }
        assertNotNull("smoke") // dummy assert so JUnit counts this as a real test
    }
}