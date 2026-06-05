// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import SimUseCore

final class OutlineCacheErrorTests: XCTestCase {

    func testReadVersionMismatch() throws {
        let tmp = makeHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = OutlineCache.directory(for: "udid-v1", home: tmp)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bogus = #"{"version":99,"udid":"udid-v1","capturedAt":"2026-05-12T00:00:00Z","screen":{"width":1,"height":1},"entries":[]}"#
        try Data(bogus.utf8).write(to: OutlineCache.file(for: "udid-v1", home: tmp))

        XCTAssertThrowsError(try OutlineCache.read(udid: "udid-v1", home: tmp)) { error in
            guard case OutlineCache.ReadError.versionMismatch(_, let got, let expected) = error else {
                XCTFail("Expected versionMismatch, got \(error)")
                return
            }
            XCTAssertEqual(got, 99)
            XCTAssertEqual(expected, OutlineCache.currentVersion)
        }
    }

    func testReadUDIDMismatch() throws {
        let tmp = makeHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let payload = OutlineCache.Payload(
            version: OutlineCache.currentVersion,
            udid: "other-udid",
            capturedAt: "2026-05-12T00:00:00Z",
            screen: .init(width: 100, height: 100),
            entries: []
        )
        try OutlineCache.writePayload(payload, udid: "queried-udid", home: tmp)

        XCTAssertThrowsError(try OutlineCache.read(udid: "queried-udid", home: tmp)) { error in
            guard case OutlineCache.ReadError.udidMismatch = error else {
                XCTFail("Expected udidMismatch, got \(error)")
                return
            }
        }
    }

    func testReadCorruptJSON() throws {
        let tmp = makeHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = OutlineCache.directory(for: "udid-c", home: tmp)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("definitely not json".utf8).write(to: OutlineCache.file(for: "udid-c", home: tmp))

        XCTAssertThrowsError(try OutlineCache.read(udid: "udid-c", home: tmp)) { error in
            guard case OutlineCache.ReadError.corrupt = error else {
                XCTFail("Expected corrupt, got \(error)")
                return
            }
        }
    }

    func testReadMissingPath() {
        let tmp = makeHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertThrowsError(try OutlineCache.read(udid: "never-written", home: tmp))
    }

    func testWriteCreatesDirectoryRecursively() throws {
        let tmp = makeHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outline = Outline(
            text: "App: X 100x100\n",
            entries: [],
            lists: [],
            screen: .init(x: 0, y: 0, width: 100, height: 100),
            appLabel: "X"
        )
        try OutlineCache.write(outline: outline, udid: "fresh-udid", home: tmp)
        let url = OutlineCache.file(for: "fresh-udid", home: tmp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAtomicWriteDoesNotLeaveTemps() throws {
        let tmp = makeHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outline = Outline(
            text: "", entries: [], lists: [],
            screen: .init(x: 0, y: 0, width: 100, height: 100),
            appLabel: "X"
        )
        try OutlineCache.write(outline: outline, udid: "udid-x", home: tmp)
        let dir = OutlineCache.directory(for: "udid-x", home: tmp)
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let temps = contents.filter { $0.contains(".tmp") }
        XCTAssertEqual(temps, [], "Found temp files left over: \(temps)")
    }

    private func makeHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-cache-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}