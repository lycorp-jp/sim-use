// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend

final class AuthTokenFetcherTests: XCTestCase {

    func testParsesJSONResultColumn() {
        let stdout = """
        Row: 0 result={"status":"success","result":"abc-def-ghi"}
        """
        XCTAssertEqual(AuthTokenFetcher.parse(stdout: stdout), "abc-def-ghi")
    }

    func testParsesRawColumnFallback() {
        let stdout = "Row: 0 result=raw-uuid-without-json"
        XCTAssertEqual(AuthTokenFetcher.parse(stdout: stdout), "raw-uuid-without-json")
    }

    func testReturnsNilWhenMissing() {
        XCTAssertNil(AuthTokenFetcher.parse(stdout: "No result found."))
        XCTAssertNil(AuthTokenFetcher.parse(stdout: ""))
    }

    // MARK: - classifyBridgeMissing

    /// The provider-absent signal travels two distinct paths:
    /// stdout when `content query` happens to exit 0 with the
    /// platform's terse "No result found." line, and stderr when
    /// the activity manager refuses the call with "Error while
    /// accessing provider" / "Unknown URL". Both must funnel into
    /// `BridgeError.bridgeNotInstalled` so the user sees the
    /// actionable "run `sim-use android init`" hint instead of a
    /// raw `adb` failure dump.
    func testClassifyBridgeMissingOnNoResultFound() {
        XCTAssertTrue(AuthTokenFetcher.outputIndicatesBridgeMissing("No result found."))
    }

    func testClassifyBridgeMissingOnUnknownUri() {
        let stderr = """
        java.lang.IllegalArgumentException: Unknown URL content://com.linecorp.simuse.devicebridge/auth_token
            at android.content.ContentResolver.acquireProvider(ContentResolver.java:1234)
        """
        XCTAssertTrue(AuthTokenFetcher.outputIndicatesBridgeMissing(stderr))
    }

    func testClassifyBridgeMissingOnAccessingProviderError() {
        let stderr = "Error while accessing provider:com.linecorp.simuse.devicebridge\nat android.content.ContentResolver..."
        XCTAssertTrue(AuthTokenFetcher.outputIndicatesBridgeMissing(stderr))
    }

    func testClassifyReturnsFalseForUnrelatedOutput() {
        XCTAssertFalse(AuthTokenFetcher.outputIndicatesBridgeMissing(""))
        XCTAssertFalse(AuthTokenFetcher.outputIndicatesBridgeMissing("Row: 0 result=ok"))
        XCTAssertFalse(AuthTokenFetcher.outputIndicatesBridgeMissing("permission denied"))
    }
}