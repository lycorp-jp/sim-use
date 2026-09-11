// SPDX-License-Identifier: Apache-2.0
import XCTest
#if canImport(os)
import os
#endif
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
        XCTAssertGreaterThan(
            result.stderr.utf8.count, 100_000,
            "most of the 200 KB stderr payload must arrive — deadlock would yield 0"
        )
        XCTAssertEqual(result.exitCode, 0)
    }

    #if canImport(os)
    /// `waitForExit` must not finalize the consumer while a readability
    /// callback has already taken bytes out of the pipe but not yet delivered
    /// them. The blocked first callback reproduces the shutdown race that
    /// previously lost the final H.264 chunk.
    func testStreamingProcessDrainsInFlightStdoutBeforeReturning() throws {
        let callbackStarted = DispatchSemaphore(value: 0)
        let unblockFirstCallback = DispatchSemaphore(value: 0)
        let waitReturned = DispatchSemaphore(value: 0)
        let callbackCount = OSAllocatedUnfairLock(initialState: 0)
        let received = OSAllocatedUnfairLock(initialState: Data())

        let process = AdbStreamingProcess(
            adbPath: "/bin/sh",
            arguments: ["-c", "printf first; sleep 0.1; printf second"],
            onStdout: { chunk in
                let count = callbackCount.withLock { count in
                    count += 1
                    return count
                }
                if count == 1 {
                    callbackStarted.signal()
                    unblockFirstCallback.wait()
                }
                received.withLock { $0.append(chunk) }
            }
        )
        try process.start()
        XCTAssertEqual(callbackStarted.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            _ = process.waitForExit(timeout: 2)
            waitReturned.signal()
        }

        let returnedBeforeRelease = waitReturned.wait(timeout: .now() + 0.5) == .success
        XCTAssertFalse(returnedBeforeRelease, "waitForExit must wait for the callback that already consumed stdout")
        if returnedBeforeRelease {
            unblockFirstCallback.signal()
            return
        }

        unblockFirstCallback.signal()
        XCTAssertEqual(waitReturned.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(String(data: received.withLock { $0 }, encoding: .utf8), "firstsecond")
    }
    #endif

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
    /// every invocation took ≥ 20 ms even when the child exited in
    /// microseconds. The terminationHandler + semaphore replacement
    /// is woken by the kernel, so an unloaded call completes in a
    /// few ms.
    ///
    /// Third design iteration. Absolute thresholds cannot separate
    /// the floor from machine load: min-of-20 against a flat 20 ms
    /// bound was observed at 21.5 ms on a busy machine — inside the
    /// ~22–23 ms a real floor would produce, so relaxing the bound
    /// would also pass the regression it guards against. Instead,
    /// pair each runner call with a floorless direct `Process` spawn
    /// of the same child and compare the two minima: load inflates
    /// both sides together, while a per-call sleep floor shows up as
    /// a stable one-sided offset of the full floor (20 ms), far above
    /// the 15 ms margin.
    func testRunFastChildHasLowLatency() throws {
        let adb = Adb(binaryPath: "/bin/sh", defaultTimeout: 5)

        func directSpawn() throws -> TimeInterval {
            let start = Date()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", ":"]
            try process.run()
            process.waitUntilExit()
            return Date().timeIntervalSince(start)
        }

        // Warm up the dyld / fork+exec path on both sides so the timed
        // loop measures steady-state cost rather than first-spawn
        // outliers.
        _ = try adb.run(args: ["-c", ":"])
        _ = try directSpawn()

        var fastestAdb = TimeInterval.infinity
        var fastestDirect = TimeInterval.infinity
        // Interleave the two so both sample the same load conditions.
        for _ in 0..<20 {
            fastestDirect = min(fastestDirect, try directSpawn())
            let start = Date()
            _ = try adb.run(args: ["-c", ":"])
            fastestAdb = min(fastestAdb, Date().timeIntervalSince(start))
        }

        XCTAssertLessThan(
            fastestAdb,
            fastestDirect + 0.015,
            """
            the fastest of 20 runner invocations should track the fastest \
            direct spawn (a per-call polling floor adds a stable ~20 ms); \
            got runner \(fastestAdb)s vs direct \(fastestDirect)s
            """
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
