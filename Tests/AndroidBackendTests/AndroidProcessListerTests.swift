// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend
@testable import SimUseCore

final class AndroidProcessListerTests: XCTestCase {

    func testParsesMainAppProcessesAndFiltersNoise() {
        let output = """
        PID NAME
        1234 com.example.app
        1250 com.example.app:pushservice
        567 system_server
        89 com.android.systemui
        901 com.google.android.gms
        112 com.google.android.apps.nexuslauncher
        2 kworker/0:0
        333 com.example.other
        """
        let map = AndroidProcessLister.parse(psOutput: output)
        // Only third-party MAIN app processes survive: sub-processes
        // (":pushservice"), system_server (no dot), system/launcher
        // packages, and kernel threads are all filtered out.
        XCTAssertEqual(map, [1234: "com.example.app", 333: "com.example.other"])
    }

    func testEmptyForSystemOnlyOrBlank() {
        XCTAssertTrue(AndroidProcessLister.parse(psOutput: "PID NAME\n567 system_server").isEmpty)
        XCTAssertTrue(AndroidProcessLister.parse(psOutput: "").isEmpty)
    }

    func testFeedsAppSnapshotLiveness() {
        let map = AndroidProcessLister.parse(psOutput: "1234 com.example.app")
        let snapshot = AppSnapshot(appsByPid: map)
        XCTAssertEqual(snapshot.liveness(ofBundleId: "com.example.app"), .alive(pid: 1234))
        XCTAssertEqual(snapshot.liveness(ofBundleId: "com.absent.app"), .dead)
    }

    func testParsePackageListStripsPrefix() {
        let output = """
        package:com.example.other
        package:com.linecorp.simuse.devicebridge
        """
        XCTAssertEqual(
            AndroidProcessLister.parsePackageList(output),
            ["com.example.other", "com.linecorp.simuse.devicebridge"]
        )
    }

    func testAllowlistKeepsOnlyInstalledThirdPartyAndStripsSystemNoise() {
        // The prefix denylist misses `com.google.process.*` and bare
        // `media.*`; a third-party-package allowlist filters them cleanly.
        let output = """
        PID NAME
        7494 com.example.other
        23830 com.google.process.gapps
        454 media.extractor
        23577 com.linecorp.simuse.devicebridge
        """
        let allow: Set<String> = ["com.example.other", "com.linecorp.simuse.devicebridge"]
        XCTAssertEqual(
            AndroidProcessLister.parse(psOutput: output, installedPackages: allow),
            [7494: "com.example.other", 23577: "com.linecorp.simuse.devicebridge"]
        )
    }
}