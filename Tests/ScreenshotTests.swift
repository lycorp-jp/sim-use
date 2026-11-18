// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Suite("Screenshot Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct ScreenshotTests {
    private static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])

    @Test("Top-level screenshot writes a real PNG to the given path")
    func screenshotToFile() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUsePath = try TestHelpers.getSimUsePath()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-screenshot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }

        let (_, _) = try await CommandRunner.run("\(simUsePath) screenshot --udid \(udid) --output \(output.path)")

        let data = try Data(contentsOf: output)
        #expect(data.prefix(4) == Self.pngMagic)
        #expect(data.count > 10_000, "screenshot should be a real image, got \(data.count) bytes")
    }

    @Test("screenshot --json returns an envelope whose path exists")
    func screenshotJSONEnvelope() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUsePath = try TestHelpers.getSimUsePath()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-screenshot-json-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }

        // CommandRunner combines both streams; only stdout is the JSON envelope.
        let (stdout, _) = try await CommandRunner.run("\(simUsePath) screenshot --udid \(udid) --output \(output.path) --json 2>/dev/null")

        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any],
            "expected a JSON envelope, got: \(stdout.prefix(200))"
        )
        #expect(json["ok"] as? Bool == true)
        let dataField = try #require(json["data"] as? [String: Any])
        let path = try #require(dataField["path"] as? String)
        #expect(FileManager.default.fileExists(atPath: path))
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(bytes.prefix(4) == Self.pngMagic)
    }

    @Test("screenshot into an existing directory stamps a filename inside it")
    func screenshotToDirectory() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUsePath = try TestHelpers.getSimUsePath()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-screenshot-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await CommandRunner.run("\(simUsePath) screenshot --udid \(udid) --output '\(dir.path)'")

        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let pngs = entries.filter { $0.pathExtension == "png" }
        #expect(pngs.count == 1, "expected exactly one stamped PNG, found \(entries.map(\.lastPathComponent))")
        if let png = pngs.first {
            let data = try Data(contentsOf: png)
            #expect(data.prefix(4) == Self.pngMagic)
        }
    }
}
