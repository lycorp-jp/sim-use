// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Suite("Preflight Script Tests")
struct PreflightScriptTests {
    @Test("device listing does not receive device-scoped options")
    func deviceListingDoesNotReceiveDeviceScopedOptions() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logFile = tempRoot.appendingPathComponent("sim-use-args.log")
        let fakeSimUse = tempRoot.appendingPathComponent("sim-use")

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try fakeSimUseScript(logFile: logFile.path).write(to: fakeSimUse, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSimUse.path)

        let result = try await CommandRunner.run(
            "python3 skills/sim-use/scripts/preflight.py --device target-device --sim-use-bin \(fakeSimUse.path)",
            allowFailure: true
        )

        #expect(result.exitCode == 0, "preflight should pass with fake sim-use: \(result.output)")
        #expect(result.output.contains("All checks passed"))

        let log = try String(contentsOf: logFile, encoding: .utf8)
        #expect(log.contains("devices --json\n"))
        #expect(!log.contains("devices --json --device target-device"))
        #expect(log.contains("ui --json --device target-device"))
    }

    private func fakeSimUseScript(logFile: String) -> String {
        """
        #!/bin/bash
        printf '%s\\n' "$*" >> "\(logFile)"

        if [[ "$1" == "devices" ]]; then
          if [[ "$*" == *"--device"* ]]; then
            echo "devices must not receive --device" >&2
            exit 2
          fi
          echo '{"ok":true,"data":{"devices":[{"deviceId":"target-device","name":"Test iPhone","platform":"ios","state":"Booted"}]}}'
          exit 0
        fi

        if [[ "$1" == "ui" ]]; then
          if [[ "$*" != *"--device target-device"* ]]; then
            echo "ui must receive --device" >&2
            exit 3
          fi
          echo '{"ok":true,"data":{"outline":"App: Test"}}'
          exit 0
        fi

        echo "unexpected command: $*" >&2
        exit 4
        """
    }
}
