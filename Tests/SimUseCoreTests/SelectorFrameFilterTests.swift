// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import SimUseCore

final class SelectorFrameFilterTests: XCTestCase {

    // MARK: - parse

    func testEmptyInputProducesEmptyFilter() throws {
        let f = try SelectorFrameFilter(specs: [])
        XCTAssertTrue(f.isEmpty)
        XCTAssertFalse(f.hasRelativeBounds)
    }

    func testParsesAbsoluteAndRelativeBounds() throws {
        let f = try SelectorFrameFilter(specs: ["minY=700", "maxY=0.9r"])
        XCTAssertEqual(f.minY, 700)
        XCTAssertEqual(f.maxYRel, 0.9)
        XCTAssertTrue(f.hasRelativeBounds)
    }

    func testCommaSeparatedKeyValuePairs() throws {
        let f = try SelectorFrameFilter(specs: ["minX=100,maxX=900"])
        XCTAssertEqual(f.minX, 100)
        XCTAssertEqual(f.maxX, 900)
    }

    func testUnknownKeyThrows() {
        XCTAssertThrowsError(try SelectorFrameFilter(specs: ["minZ=100"])) { error in
            guard let parseError = error as? SelectorFrameFilter.ParseError else {
                XCTFail("expected ParseError; got \(error)")
                return
            }
            XCTAssertTrue(parseError.message.contains("minZ"))
        }
    }

    func testDuplicateKeyThrows() {
        XCTAssertThrowsError(try SelectorFrameFilter(specs: ["minY=100", "minY=200"]))
    }

    func testNonNumericValueThrows() {
        XCTAssertThrowsError(try SelectorFrameFilter(specs: ["minY=abc"]))
    }

    func testRelativeOutOfRangeThrows() {
        XCTAssertThrowsError(try SelectorFrameFilter(specs: ["minY=1.5r"]))
        XCTAssertThrowsError(try SelectorFrameFilter(specs: ["minX=-0.1r"]))
    }

    func testInvertedBoundsThrows() {
        XCTAssertThrowsError(try SelectorFrameFilter(specs: ["minY=900,maxY=100"]))
        XCTAssertThrowsError(try SelectorFrameFilter(specs: ["minY=0.9r,maxY=0.1r"]))
    }

    // MARK: - resolved

    func testResolvedAgainstScreenConvertsRelativeToAbsolute() throws {
        let f = try SelectorFrameFilter(specs: ["minY=0.5r"])
        let resolved = f.resolved(screen: Outline.Frame(x: 0, y: 0, width: 1080, height: 2400))
        XCTAssertEqual(resolved.minY, 1200)
        XCTAssertNil(resolved.minYRel, "relative bound consumed during resolve")
        XCTAssertFalse(resolved.hasRelativeBounds)
    }

    /// Absolute bounds round-trip unchanged through `resolved`. Resolving
    /// is purely about turning relative bands into absolute pixels.
    func testResolvedPreservesAbsoluteBounds() throws {
        let f = try SelectorFrameFilter(specs: ["minY=700"])
        let resolved = f.resolved(screen: Outline.Frame(x: 0, y: 0, width: 1080, height: 2400))
        XCTAssertEqual(resolved.minY, 700)
    }

    // MARK: - contains

    func testContainsAcceptsFrameInsideBand() throws {
        let f = try SelectorFrameFilter(specs: ["minY=500"])
        let resolved = f.resolved(screen: Outline.Frame(x: 0, y: 0, width: 1080, height: 2400))
        XCTAssertTrue(resolved.contains(Outline.Frame(x: 100, y: 800, width: 200, height: 100)))
        XCTAssertFalse(resolved.contains(Outline.Frame(x: 100, y: 400, width: 200, height: 100)))
    }

    func testContainsHonoursMaxBound() throws {
        let f = try SelectorFrameFilter(specs: ["maxY=1200"])
        let resolved = f.resolved(screen: Outline.Frame(x: 0, y: 0, width: 1080, height: 2400))
        XCTAssertTrue(resolved.contains(Outline.Frame(x: 100, y: 800, width: 200, height: 100)))
        XCTAssertFalse(resolved.contains(Outline.Frame(x: 100, y: 1500, width: 200, height: 100)))
    }

    /// Both axes constrained — element must satisfy each bound.
    func testContainsRequiresAllBounds() throws {
        let f = try SelectorFrameFilter(specs: ["minX=200,maxX=900,minY=500,maxY=1200"])
        let resolved = f.resolved(screen: Outline.Frame(x: 0, y: 0, width: 1080, height: 2400))
        XCTAssertTrue(resolved.contains(Outline.Frame(x: 400, y: 700, width: 100, height: 100)))
        XCTAssertFalse(resolved.contains(Outline.Frame(x: 100, y: 700, width: 100, height: 100))) // x below
        XCTAssertFalse(resolved.contains(Outline.Frame(x: 400, y: 200, width: 100, height: 100))) // y below
    }
}