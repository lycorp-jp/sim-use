// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Suite("Preflight Script Tests")
struct PreflightScriptTests {
    @Test("device listing does not receive device-scoped options")
    func deviceListingDoesNotReceiveDeviceScopedOptions() async throws {
        let fixture = try makeFakeSimUse(versionStamp: "0.14.0")
        defer { try? FileManager.default.removeItem(at: fixture.tempRoot) }

        let result = try await runPreflight(fakeSimUse: fixture.executable)

        #expect(result.exitCode == 0, "preflight should pass with fake sim-use: \(result.output)")
        #expect(result.output.contains("All checks passed"))

        let log = try String(contentsOf: fixture.logFile, encoding: .utf8)
        #expect(log.contains("--version\n"))
        #expect(log.contains("devices --json\n"))
        #expect(!log.contains("devices --json --device target-device"))
        #expect(log.contains("ui --json --device target-device"))
    }

    @Test("version compatibility follows release normalization", arguments: [
        (stamp: "0.14.0", versionExitCode: 0, expectedPass: true),
        (stamp: "0.15.0", versionExitCode: 0, expectedPass: true),
        (stamp: "v0.14.0", versionExitCode: 0, expectedPass: true),
        (stamp: "v0.14.0-3-gabc1234-dirty", versionExitCode: 0, expectedPass: true),
        (stamp: "dev", versionExitCode: 0, expectedPass: true),
        (stamp: "0.13.0", versionExitCode: 0, expectedPass: false),
        (stamp: "v0.13.0-5-gabc1234", versionExitCode: 0, expectedPass: true),
        (stamp: "0.14.0", versionExitCode: 7, expectedPass: false),
    ])
    func versionCompatibility(
        _ testCase: (stamp: String, versionExitCode: Int, expectedPass: Bool)
    ) async throws {
        let fixture = try makeFakeSimUse(
            versionStamp: testCase.stamp,
            versionExitCode: testCase.versionExitCode
        )
        defer { try? FileManager.default.removeItem(at: fixture.tempRoot) }

        let result = try await runPreflight(fakeSimUse: fixture.executable)
        let expectedExitCode = testCase.expectedPass ? 0 : 1
        #expect(
            result.exitCode == expectedExitCode,
            "unexpected preflight result for version stamp \(testCase.stamp): \(result.output)"
        )

        let log = try String(contentsOf: fixture.logFile, encoding: .utf8)
        if testCase.expectedPass {
            #expect(result.output.contains("All checks passed"))
            #expect(log.contains("devices --json\n"))
            #expect(log.contains("ui --json --device target-device\n"))
        } else {
            #expect(result.output.contains("FAIL  sim-use version is compatible with this skill"))
            #expect(result.output.contains("brew upgrade lycorp-jp/tap/sim-use"))
            #expect(log == "--version\n")
        }
    }

    @Test("remote content recovery warns without failing or restarting the daemon", arguments: [
        #"{"ok":true,"advisory":{"kind":"remote_content_recovery"},"data":{"platform":"ios","screen":{"width":0,"height":0},"entries":[{"role":"StaticText","label":"12:00"}]}}"#,
        #"{"ok":true,"advisory":{"kind":"remote_content_recovery"},"data":{"platform":"ios","entries":[{"role":"Button","label":"Browse"},{"role":"Button","label":"Cancel"}]}}"#,
    ])
    func remoteContentRecoveryWarns(uiResponse: String) async throws {
        let fixture = try makeFakeSimUse(versionStamp: "0.14.0", uiResponse: uiResponse)
        defer { try? FileManager.default.removeItem(at: fixture.tempRoot) }

        let result = try await runPreflight(fakeSimUse: fixture.executable)

        #expect(result.exitCode == 0)
        #expect(result.output.contains("PASS  sim-use ui returns a valid response"))
        #expect(result.output.contains("WARN"))
        #expect(result.output.contains("remote_content_recovery"))
        #expect(result.output.contains("system picker"))
        #expect(result.output.contains("If visible app controls are missing"))
        #expect(result.output.contains("ApplicationAccessibilityEnabled"))
        #expect(result.output.contains("relaunch"))
        #expect(result.output.contains("Preflight passed with a content warning"))
        #expect(!result.output.contains("All checks passed"))
        #expect(!result.output.contains("FAIL"))
        #expect(!result.output.contains("FIX"))

        let log = try String(contentsOf: fixture.logFile, encoding: .utf8)
        #expect(log == "--version\ndevices --json\nui --json --device target-device\n")
    }

    @Test("successful reads without the recovery advisory keep the existing result", arguments: [
        #"{"ok":true,"data":{"platform":"ios","entries":[{"role":"StaticText","label":"12:00"}]}}"#,
        #"{"ok":true,"advisory":null,"data":{"outline":"App: Test"}}"#,
        #"{"ok":true,"advisory":{"kind":"orientation_uncertain"},"data":{"outline":"App: Test"}}"#,
        #"{"ok":true,"data":{"platform":"android","entries":[]}}"#,
        #"{"ok":true,"data":{"kind":"physical","outline":"Button: Close"}}"#,
    ])
    func successfulReadWithoutRecoveryDoesNotWarn(uiResponse: String) async throws {
        let fixture = try makeFakeSimUse(versionStamp: "0.14.0", uiResponse: uiResponse)
        defer { try? FileManager.default.removeItem(at: fixture.tempRoot) }

        let result = try await runPreflight(fakeSimUse: fixture.executable)

        #expect(result.exitCode == 0)
        #expect(result.output.contains("All checks passed"))
        #expect(!result.output.contains("WARN"))
        #expect(!result.output.contains("ApplicationAccessibilityEnabled"))
    }

    @Test("unsuccessful UI reads still retry and fail", arguments: [
        (response: #"{"ok":false,"advisory":{"kind":"remote_content_recovery"}}"#, exitCode: 0),
        (response: #"{"ok":true,"advisory":{"kind":"remote_content_recovery"}}"#, exitCode: 7),
        (response: "invalid JSON", exitCode: 0),
    ])
    func unsuccessfulReadStillFails(_ testCase: (response: String, exitCode: Int)) async throws {
        let fixture = try makeFakeSimUse(
            versionStamp: "0.14.0",
            uiResponse: testCase.response,
            uiExitCode: testCase.exitCode
        )
        defer { try? FileManager.default.removeItem(at: fixture.tempRoot) }

        let result = try await runPreflight(fakeSimUse: fixture.executable)

        #expect(result.exitCode == 1)
        #expect(result.output.contains("FAIL  sim-use ui returns a valid response"))
        #expect(result.output.contains("Preflight failed: ui_responds"))
        #expect(!result.output.contains("WARN"))

        let log = try String(contentsOf: fixture.logFile, encoding: .utf8)
        #expect(log == "--version\ndevices --json\nui --json --device target-device\ndaemon stop --all\nui --json --device target-device\n")
    }

    private func runPreflight(fakeSimUse: URL) async throws -> (output: String, exitCode: Int32) {
        try await CommandRunner.run(
            "python3 skills/sim-use/scripts/preflight.py --device target-device --sim-use-bin \(fakeSimUse.path)",
            allowFailure: true
        )
    }

    private func makeFakeSimUse(
        versionStamp: String,
        versionExitCode: Int = 0,
        uiResponse: String = #"{"ok":true,"data":{"outline":"App: Test"}}"#,
        uiExitCode: Int = 0
    ) throws -> (tempRoot: URL, executable: URL, logFile: URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logFile = tempRoot.appendingPathComponent("sim-use-args.log")
        let executable = tempRoot.appendingPathComponent("sim-use")

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try fakeSimUseScript(
            logFile: logFile.path,
            versionStamp: versionStamp,
            versionExitCode: versionExitCode,
            uiResponse: uiResponse,
            uiExitCode: uiExitCode
        ).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        return (tempRoot, executable, logFile)
    }

    private func fakeSimUseScript(
        logFile: String,
        versionStamp: String,
        versionExitCode: Int,
        uiResponse: String,
        uiExitCode: Int
    ) -> String {
        """
        #!/bin/bash
        printf '%s\\n' "$*" >> "\(logFile)"

        if [[ "$1" == "--version" ]]; then
          echo "\(versionStamp)"
          exit \(versionExitCode)
        fi

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
          cat <<'PREFLIGHT_UI_RESPONSE'
        \(uiResponse)
        PREFLIGHT_UI_RESPONSE
          exit \(uiExitCode)
        fi

        if [[ "$*" == "daemon stop --all" ]]; then
          exit 0
        fi

        echo "unexpected command: $*" >&2
        exit 4
        """
    }
}
