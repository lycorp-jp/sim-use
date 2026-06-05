// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend

final class AdbDiscoveryTests: XCTestCase {

    func testHonoursSIMUseAdbOverride() {
        let custom = "/some/custom/adb-stub"
        let env = ["SIM_USE_ADB": custom]
        XCTAssertEqual(Adb.discover(env: env), custom)
    }

    func testPrefersAndroidSDKRootWhenSet() throws {
        let tmp = try makeTempSDK(name: "android-sdk-root")
        defer { try? FileManager.default.removeItem(at: tmp.root) }
        let env = ["ANDROID_SDK_ROOT": tmp.root.path]
        XCTAssertEqual(Adb.discover(env: env), tmp.adb.path)
    }

    func testFallsBackToAndroidHomeWhenRootMissing() throws {
        let tmp = try makeTempSDK(name: "android-home")
        defer { try? FileManager.default.removeItem(at: tmp.root) }
        let env = ["ANDROID_HOME": tmp.root.path]
        XCTAssertEqual(Adb.discover(env: env), tmp.adb.path)
    }

    func testFallsBackToHomeLibraryLayout() throws {
        let tmp = try makeTempSDK(name: "user-home", layout: ["Library", "Android", "sdk", "platform-tools", "adb"])
        defer { try? FileManager.default.removeItem(at: tmp.root) }
        let env = ["HOME": tmp.root.path]
        XCTAssertEqual(Adb.discover(env: env), tmp.adb.path)
    }

    func testFinalFallbackReturnsBareName() {
        let env: [String: String] = [:]
        // No env hints, no candidates writable in this run — falls back
        // to bare "adb" (PATH resolution happens at `run()` time).
        let resolved = Adb.discover(env: env)
        XCTAssertTrue(resolved == "adb" || resolved.hasSuffix("/adb"))
    }

    // MARK: - resolveOnPATH

    func testResolveOnPATHReturnsNilForAbsolute() {
        XCTAssertNil(Adb.resolveOnPATH("/usr/bin/foo", env: ["PATH": "/bin"]))
        XCTAssertNil(Adb.resolveOnPATH("./adb", env: ["PATH": "/bin"]))
    }

    func testResolveOnPATHFindsBinary() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("adb-path-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let stub = tmp.appendingPathComponent("fake-bin")
        try "#!/bin/sh\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let env = ["PATH": tmp.path]
        XCTAssertEqual(Adb.resolveOnPATH("fake-bin", env: env), stub.path)
    }

    // MARK: - helpers

    private struct TempSDK {
        let root: URL
        let adb: URL
    }

    private func makeTempSDK(name: String, layout: [String] = ["platform-tools", "adb"]) throws -> TempSDK {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        var current = root
        for component in layout.dropLast() {
            current.appendPathComponent(component, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let adb = current.appendingPathComponent(layout.last!)
        try "#!/bin/sh\nexit 0\n".write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        return TempSDK(root: root, adb: adb)
    }
}