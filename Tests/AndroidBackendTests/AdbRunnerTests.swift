// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend

/// Integration-level tests for `Adb.run(args:)`. These spawn real
/// processes (against `/bin/sh`) to exercise pipe-buffer behaviour
/// and error-mapping paths that pure-string parsers can't cover.
/// Kept POSIX-only (`/bin/sh`) so the tests are portable across
/// macOS and Linux CI runners.
final class AdbRunnerTests: XCTestCase {

    /// Repro for the pipe-drain deadlock. With the old runner the
    /// 200 KB stdout filled the kernel pipe buffer (~64 KB), the
    /// child blocked on write, `process.isRunning` stayed true, and
    /// the 3-second timeout fired. After the readabilityHandler-
    /// based drain the child completes immediately and the full
    /// payload arrives on `RunResult.stdout`.
    func testRunDoesNotDeadlockOnLargeStdout() throws {
        let adb = Adb(binaryPath: "/bin/sh", defaultTimeout: 3)
        // 200 000 zero bytes — well over the per-pipe buffer on
        // every POSIX kernel we ship to. `tr` rewrites to ASCII so
        // the UTF-8 decode at the end of `run` doesn't drop bytes.
        let result = try adb.run(args: [
            "-c",
            "head -c 200000 /dev/zero | tr '\\0' 'a'",
        ])
        XCTAssertEqual(
            result.stdout.utf8.count,
            200_000,
            "all 200 KB of stdout must reach the caller — pipe drain is the contract"
        )
        XCTAssertEqual(result.exitCode, 0)
    }

    /// Stderr must drain the same way — a chatty child that writes
    /// MB of warnings to stderr must not hang the call.
    func testRunDoesNotDeadlockOnLargeStderr() throws {
        let adb = Adb(binaryPath: "/bin/sh", defaultTimeout: 3)
        let result = try adb.run(args: [
            "-c",
            "head -c 200000 /dev/zero | tr '\\0' 'b' 1>&2",
        ])
        XCTAssertEqual(result.stderr.utf8.count, 200_000)
        XCTAssertEqual(result.exitCode, 0)
    }

    /// Sanity check that a process exceeding the timeout still
    /// surfaces a timeout error (not a deadlock, not a 0-exit
    /// success). The post-terminate wait gives the child a chance
    /// to clean up before we throw.
    func testRunTimeoutOnSlowChild() {
        let adb = Adb(binaryPath: "/bin/sh", defaultTimeout: 0.3)
        XCTAssertThrowsError(try adb.run(args: ["-c", "sleep 5"])) { error in
            guard case BridgeError.adbFailure(_, _, let stderr) = error else {
                XCTFail("expected .adbFailure with timeout marker; got \(error)")
                return
            }
            XCTAssertTrue(stderr.contains("timed out"),
                          "stderr should mention timeout; got: \(stderr)")
        }
    }

    /// A burst of fast children must not be paced by the wait loop.
    /// The old runner had a 20 ms `Thread.sleep` floor per call, so
    /// 20 invocations took ≥ 400 ms even when each child exited in
    /// microseconds. The terminationHandler + semaphore replacement
    /// is woken by the kernel and wall time collapses to the cost
    /// of `Process.run()` itself.
    func testRunFastChildHasLowLatency() throws {
        let adb = Adb(binaryPath: "/bin/sh", defaultTimeout: 5)
        // Warm up the dyld / fork+exec path so the timed loop below
        // measures steady-state cost rather than first-spawn outliers.
        _ = try adb.run(args: ["-c", ":"])
        let start = Date()
        for _ in 0..<20 {
            _ = try adb.run(args: ["-c", ":"])
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed,
            0.3,
            "20 fast adb invocations should not be paced by polling; got \(elapsed)s"
        )
    }

    /// Missing binary should map to `.adbMissing`, not the generic
    /// transport error. Regression guard for the brittle
    /// NSCocoaErrorDomain code-4 check that previously missed
    /// POSIX-domain ENOENT.
    func testRunMapsMissingBinaryToAdbMissing() {
        let adb = Adb(binaryPath: "/no/such/path/__definitely_not_here__")
        XCTAssertThrowsError(try adb.run(args: ["devices"])) { error in
            guard case BridgeError.adbMissing = error else {
                XCTFail("expected .adbMissing; got \(error)")
                return
            }
        }
    }
}