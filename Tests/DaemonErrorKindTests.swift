// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import Foundation
import Testing
@testable import SimUseCore

// MARK: - Fixtures

private struct MessageError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { self.errorDescription = message }
}

// MARK: - Classification rules

@Suite("DaemonErrorKind.classify")
struct DaemonErrorKindClassifyTests {
    @Test("Messages containing 'as it is not booted' map to transientBooting")
    func notBooted() {
        let error = MessageError("Simulator ABC not available as it is not booted")
        #expect(DaemonErrorKind.classify(error) == .transientBooting)
    }

    @Test("Messages containing 'No translation object returned for simulator' map to transientBooting")
    func noTranslation() {
        let error = MessageError("No translation object returned for simulator ABC")
        #expect(DaemonErrorKind.classify(error) == .transientBooting)
    }

    @Test("Unrelated errors fall back to .other")
    func unrelatedFallsBackToOther() {
        #expect(DaemonErrorKind.classify(MessageError("Something else entirely")) == .other)
        #expect(DaemonErrorKind.classify(MessageError("")) == .other)
    }

    @Test("Substring match is enough; extra surrounding text is fine")
    func substringMatch() {
        let error = MessageError("... internal error: as it is not booted (retries exhausted)")
        #expect(DaemonErrorKind.classify(error) == .transientBooting)
    }

    // LINEIOS-216942: classify "the daemon's simulator was shut down out
    // of band" so the daemon can self-terminate and surface an
    // actionable hint instead of a terse "not found in set" error.

    @Test("'not found in set' messages map to staleSimulator")
    func notFoundInSetIsStale() {
        let error = MessageError("Simulator with UDID ABCD not found in set.")
        #expect(DaemonErrorKind.classify(error) == .staleSimulator)
    }

    @Test("'is not booted. Current state:' messages map to staleSimulator")
    func explicitStateIsStale() {
        let error = MessageError("Simulator with UDID ABCD is not booted. Current state: 1")
        #expect(DaemonErrorKind.classify(error) == .staleSimulator)
    }

    @Test("transient-booting phrasing wins over stale phrasing when both could match")
    func transientWinsOverStale() {
        // FBSimulatorControl emits "as it is not booted" while the sim
        // is still booting; we must NOT misclassify that as stale.
        let error = MessageError("Simulator ABCD failed as it is not booted")
        #expect(DaemonErrorKind.classify(error) == .transientBooting)
    }
}

// MARK: - Raw value / wire format

@Suite("DaemonErrorKind raw values")
struct DaemonErrorKindRawValueTests {
    @Test("Raw values match the JSON wire contract")
    func rawValues() {
        #expect(DaemonErrorKind.permanent.rawValue == "permanent")
        #expect(DaemonErrorKind.transientBooting.rawValue == "transient_booting")
        #expect(DaemonErrorKind.staleSimulator.rawValue == "stale_simulator")
        #expect(DaemonErrorKind.other.rawValue == "other")
    }

    @Test("JSON encode/decode round-trips via rawValue")
    func codableRoundTrip() throws {
        for kind in [DaemonErrorKind.permanent, .transientBooting, .staleSimulator, .other] {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(DaemonErrorKind.self, from: data)
            #expect(decoded == kind)
        }
    }

    @Test("Decoding an unknown kind string fails (no silent fallback)")
    func unknownKindFails() {
        let bogus = Data("\"brand-new-kind\"".utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(DaemonErrorKind.self, from: bogus)
        }
    }
}