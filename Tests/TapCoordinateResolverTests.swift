// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import Testing
@testable import SimUseCore

/// Direct contract tests for `TapCoordinateResolver` — the shared
/// `--point` / `-x`/`-y` resolution used by every tap surface
/// (top-level, `ios`, `android`, batch). CLI-level coverage lives in
/// `TapValidationTests`; this suite pins the resolver semantics the
/// surfaces delegate to.
@Suite("TapCoordinateResolver")
struct TapCoordinateResolverTests {
    @Test("--point resolves to its pair")
    func pointResolves() throws {
        let resolved = try TapCoordinateResolver.resolve(
            x: nil, y: nil, point: CoordinatePair(x: 12.5, y: 36)
        )
        #expect(resolved == CoordinatePair(x: 12.5, y: 36))
    }

    @Test("-x/-y resolves to a pair")
    func legacyResolves() throws {
        let resolved = try TapCoordinateResolver.resolve(x: 100, y: 200, point: nil)
        #expect(resolved == CoordinatePair(x: 100, y: 200))
    }

    @Test("no coordinate form resolves to nil")
    func nothingGivenResolvesNil() throws {
        #expect(try TapCoordinateResolver.resolve(x: nil, y: nil, point: nil) == nil)
    }

    @Test("mixed forms throw")
    func mixedFormsThrow() {
        do {
            _ = try TapCoordinateResolver.resolve(
                x: 100, y: nil, point: CoordinatePair(x: 1, y: 2)
            )
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("only one tap coordinate form"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("partial -x/-y throws")
    func partialLegacyThrows() {
        do {
            _ = try TapCoordinateResolver.resolve(x: 100, y: nil, point: nil)
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("Both -x and -y"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("range rules match swipe", arguments: [
        (CoordinatePair(x: .infinity, y: 5), "finite"),
        (CoordinatePair(x: 5, y: .nan), "finite"),
        (CoordinatePair(x: -1, y: 5), "non-negative"),
        (CoordinatePair(x: 5, y: 1e19), "at most"),
    ])
    func rangeRules(point: CoordinatePair, fragment: String) {
        do {
            _ = try TapCoordinateResolver.resolve(x: nil, y: nil, point: point)
            Issue.record("expected ValidationError for \(point)")
        } catch let error as ValidationError {
            #expect(error.message.contains(fragment))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("range rules also cover -x/-y values")
    func rangeRulesCoverLegacy() {
        // `-x inf -y 5` used to pass the old `>= 0` check and trap the
        // Double→Int conversion on the Android forward path.
        do {
            _ = try TapCoordinateResolver.resolve(x: .infinity, y: 5, point: nil)
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("finite"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }
}
