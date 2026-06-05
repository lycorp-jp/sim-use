// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import SimUseCore

final class OutlineCacheRoundTripTests: XCTestCase {

    func testWriteAndReadRoundTrip() throws {
        let entries = [
            Outline.Entry(
                aliases: .init(at: 1),
                role: "Button",
                label: "Log in",
                frame: .init(x: 100, y: 200, width: 300, height: 80),
                region: .init(kind: "Content"),
                states: [],
                uniqueId: "login_button"
            )
        ]
        let outline = Outline(
            text: "App: LINE  1080x1920\n\n[Content  y=120..1800]\n  @1  Button  \"Log in\"  #login_button  (100,200 300x80)\n",
            entries: entries,
            lists: [],
            screen: .init(x: 0, y: 0, width: 1080, height: 1920),
            appLabel: "LINE"
        )
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-core-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        try OutlineCache.write(outline: outline, udid: "emulator-5554", home: tmp)
        let payload = try OutlineCache.read(udid: "emulator-5554", home: tmp)

        XCTAssertEqual(payload.version, OutlineCache.currentVersion)
        XCTAssertEqual(payload.udid, "emulator-5554")
        XCTAssertEqual(payload.entries.count, 1)
        XCTAssertEqual(payload.entries[0].aliases.at, 1)
        XCTAssertEqual(payload.entries[0].label, "Log in")
        XCTAssertEqual(payload.entries[0].x, 250)
        XCTAssertEqual(payload.entries[0].y, 240)
        XCTAssertEqual(payload.screen.width, 1080)
    }

    func testReadMissingThrowsMissingError() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-core-test-\(UUID().uuidString)", isDirectory: true)
        XCTAssertThrowsError(try OutlineCache.read(udid: "emulator-9999", home: tmp)) { error in
            guard let readError = error as? OutlineCache.ReadError else {
                XCTFail("Expected OutlineCache.ReadError, got \(error)")
                return
            }
            switch readError {
            case .missing: break
            default: XCTFail("Expected .missing, got \(readError)")
            }
        }
    }
}