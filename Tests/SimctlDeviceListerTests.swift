// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import SimUseCore
import XCTest

/// Unit tests for `SimctlDeviceLister.parse` (the parser path) and the
/// runtime-identifier translator. We don't shell out to `xcrun simctl`
/// here; those paths get covered by manual + smoke verification.
final class SimctlDeviceListerTests: XCTestCase {

    // MARK: - parse()

    func testParsesEmptyEnvelope() throws {
        let json = #"""
        {"devices": {}}
        """#.data(using: .utf8)!
        let devices = try SimctlDeviceLister.parse(json)
        XCTAssertEqual(devices, [])
    }

    func testParsesSingleBootedDevice() throws {
        let json = #"""
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-6": [
              {"udid": "AC274B6B-9C2B-41B1-B82C-5A1D223F4D4E",
               "name": "iPhone 16 Pro",
               "state": "Booted"}
            ]
          }
        }
        """#.data(using: .utf8)!
        let devices = try SimctlDeviceLister.parse(json)
        XCTAssertEqual(devices.count, 1)
        let device = try XCTUnwrap(devices.first)
        XCTAssertEqual(device.udid, "AC274B6B-9C2B-41B1-B82C-5A1D223F4D4E")
        XCTAssertEqual(device.name, "iPhone 16 Pro")
        XCTAssertEqual(device.platform, .ios)
        XCTAssertEqual(device.state, "Booted")
        XCTAssertEqual(device.runtime, "iOS 18.6")
        XCTAssertTrue(device.isUsable)
    }

    func testFlattensAcrossRuntimesAndSortsStably() throws {
        // Two runtimes, three devices total. Output must be stable across
        // dict iteration ordering so two consecutive invocations against
        // the same set of sims produce byte-identical output.
        let json = #"""
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-6": [
              {"udid": "B-UDID", "name": "iPad Air", "state": "Shutdown"},
              {"udid": "A-UDID", "name": "iPhone 16", "state": "Shutdown"}
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-11-5": [
              {"udid": "C-UDID", "name": "Apple Watch SE", "state": "Shutdown"}
            ]
          }
        }
        """#.data(using: .utf8)!
        let devices = try SimctlDeviceLister.parse(json)
        XCTAssertEqual(devices.count, 3)
        // Sort key: runtime asc → name asc → udid asc.
        XCTAssertEqual(devices[0].runtime, "iOS 18.6")
        XCTAssertEqual(devices[0].name, "iPad Air")
        XCTAssertEqual(devices[1].runtime, "iOS 18.6")
        XCTAssertEqual(devices[1].name, "iPhone 16")
        XCTAssertEqual(devices[2].runtime, "watchOS 11.5")
        XCTAssertEqual(devices[2].name, "Apple Watch SE")
    }

    func testShutdownDeviceIsNotUsable() throws {
        let json = #"""
        {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-6":
          [{"udid": "u", "name": "n", "state": "Shutdown"}]}}
        """#.data(using: .utf8)!
        let device = try XCTUnwrap(SimctlDeviceLister.parse(json).first)
        XCTAssertEqual(device.state, "Shutdown")
        XCTAssertFalse(device.isUsable, "Shutdown sim should fail isUsable so default --booted hides it")
    }

    func testRejectsMalformedJSON() {
        let bad = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try SimctlDeviceLister.parse(bad)) { error in
            guard case SimctlDeviceLister.ListerError.simctlFailed = error else {
                return XCTFail("expected ListerError.simctlFailed, got \(error)")
            }
        }
    }

    // MARK: - friendlyRuntime()

    func testFriendlyRuntimeForIOS() {
        XCTAssertEqual(
            SimctlDeviceLister.friendlyRuntime("com.apple.CoreSimulator.SimRuntime.iOS-18-6"),
            "iOS 18.6"
        )
    }

    func testFriendlyRuntimeForWatchOS() {
        XCTAssertEqual(
            SimctlDeviceLister.friendlyRuntime("com.apple.CoreSimulator.SimRuntime.watchOS-26-1"),
            "watchOS 26.1"
        )
    }

    func testFriendlyRuntimeForVisionOS() {
        XCTAssertEqual(
            SimctlDeviceLister.friendlyRuntime("com.apple.CoreSimulator.SimRuntime.visionOS-26-4"),
            "visionOS 26.4"
        )
    }

    /// Hypothetical patch-level runtime — three-component version.
    /// Existing coverage only pinned two-component shapes; this test
    /// guards the dash→dot loop so a future simctl that emits a
    /// patch release doesn't trip the formatter.
    func testFriendlyRuntimeForThreeComponentVersion() {
        XCTAssertEqual(
            SimctlDeviceLister.friendlyRuntime("com.apple.CoreSimulator.SimRuntime.iOS-18-6-2"),
            "iOS 18.6.2"
        )
    }

    func testFriendlyRuntimeFallsThroughForUnknownShape() {
        // Don't drop information silently — anything outside the
        // `com.apple.CoreSimulator.SimRuntime.` namespace gets passed
        // through unchanged so the caller sees the raw identifier.
        XCTAssertEqual(
            SimctlDeviceLister.friendlyRuntime("unknown.format"),
            "unknown.format"
        )
    }
}