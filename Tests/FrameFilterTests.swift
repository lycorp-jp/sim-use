// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import Foundation
import Testing

private typealias FrameFilter = AccessibilityTargetResolver.FrameFilter
private typealias ParseError = AccessibilityTargetResolver.FrameFilter.ParseError

private func makeFrame(x: Double, y: Double, w: Double = 50, h: Double = 50) throws -> AccessibilityElement.Frame {
    let dict: [String: Any] = ["x": x, "y": y, "width": w, "height": h]
    let data = try JSONSerialization.data(withJSONObject: dict)
    return try JSONDecoder().decode(AccessibilityElement.Frame.self, from: data)
}

// MARK: - Parser happy paths

@Suite("FrameFilter parser — happy paths")
struct FrameFilterParserHappyTests {
    @Test("empty specs yield an empty filter")
    func emptySpecs() throws {
        let filter = try FrameFilter(specs: [])
        #expect(filter.isEmpty)
        #expect(!filter.hasRelativeBounds)
    }

    @Test("single absolute pair")
    func singleAbsolutePair() throws {
        let filter = try FrameFilter(specs: ["minY=700"])
        #expect(filter.minY == 700)
        #expect(filter.minYRel == nil)
        #expect(filter.hasRelativeBounds == false)
    }

    @Test("single relative pair with r suffix")
    func singleRelativePair() throws {
        let filter = try FrameFilter(specs: ["minY=0.6r"])
        #expect(filter.minYRel == 0.6)
        #expect(filter.minY == nil)
        #expect(filter.hasRelativeBounds)
    }

    @Test("all four absolute axes parsed in one spec")
    func allAbsoluteAxes() throws {
        let filter = try FrameFilter(specs: ["minX=10,maxX=200,minY=50,maxY=400"])
        #expect(filter.minX == 10)
        #expect(filter.maxX == 200)
        #expect(filter.minY == 50)
        #expect(filter.maxY == 400)
    }

    @Test("abs and rel on different axes coexist")
    func mixedAbsRelDifferentAxes() throws {
        let filter = try FrameFilter(specs: ["minX=10", "minY=0.5r"])
        #expect(filter.minX == 10)
        #expect(filter.minYRel == 0.5)
        #expect(filter.hasRelativeBounds)
    }

    @Test("multiple --frame flags AND together")
    func multiFlagAccumulates() throws {
        let filter = try FrameFilter(specs: ["minX=10", "maxY=200"])
        #expect(filter.minX == 10)
        #expect(filter.maxY == 200)
    }

    @Test("whitespace around key and value is trimmed")
    func whitespaceTolerance() throws {
        let filter = try FrameFilter(specs: ["  minY = 700 "])
        #expect(filter.minY == 700)
    }

    @Test("rel boundary values 0 and 1 are accepted")
    func relBoundary() throws {
        let lo = try FrameFilter(specs: ["minY=0r"])
        let hi = try FrameFilter(specs: ["maxY=1r"])
        #expect(lo.minYRel == 0)
        #expect(hi.maxYRel == 1)
    }
}

// MARK: - Parser errors

@Suite("FrameFilter parser — error cases")
struct FrameFilterParserErrorTests {
    private func expectParseError(_ specs: [String], messageContains needle: String) {
        do {
            _ = try FrameFilter(specs: specs)
            Issue.record("Expected ParseError for specs=\(specs)")
        } catch let error as ParseError {
            #expect(error.message.contains(needle), "Message '\(error.message)' did not contain '\(needle)'")
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("empty entry from trailing comma")
    func emptyEntryComma() {
        expectParseError(["minY=700,"], messageContains: "empty")
    }

    @Test("entry without =")
    func missingEquals() {
        expectParseError(["minY700"], messageContains: "key=value")
    }

    @Test("unknown key")
    func unknownKey() {
        expectParseError(["foo=10"], messageContains: "unknown")
    }

    @Test("duplicate key within one spec")
    func duplicateKeyWithinSpec() {
        expectParseError(["minY=700,minY=200"], messageContains: "more than once")
    }

    @Test("duplicate key across specs")
    func duplicateKeyAcrossSpecs() {
        expectParseError(["minY=700", "minY=200"], messageContains: "more than once")
    }

    @Test("abs and rel on the same key both count as duplicates")
    func absRelSameKeyConflict() {
        // minY=700 and minY=0.6r are both 'minY' — second occurrence triggers duplicate.
        expectParseError(["minY=700", "minY=0.6r"], messageContains: "more than once")
    }

    @Test("non-numeric value")
    func nonNumericValue() {
        expectParseError(["minY=abc"], messageContains: "not a number")
    }

    @Test("relative value above 1")
    func relAboveOne() {
        expectParseError(["minY=1.5r"], messageContains: "0…1")
    }

    @Test("relative value below 0")
    func relBelowZero() {
        expectParseError(["minY=-0.1r"], messageContains: "0…1")
    }

    @Test("absolute minX > maxX rejected")
    func absMinXAboveMaxX() {
        expectParseError(["minX=300,maxX=10"], messageContains: "≤")
    }

    @Test("absolute minY > maxY rejected")
    func absMinYAboveMaxY() {
        expectParseError(["minY=300,maxY=10"], messageContains: "≤")
    }

    @Test("relative minX > maxX rejected")
    func relMinXAboveMaxX() {
        expectParseError(["minX=0.7r,maxX=0.3r"], messageContains: "≤")
    }
}

// MARK: - contains()

@Suite("FrameFilter contains() — geometry")
struct FrameFilterContainsTests {
    @Test("nil frame is never contained")
    func nilFrame() {
        let filter = try! FrameFilter(specs: ["minY=100"])
        #expect(!filter.contains(nil))
    }

    @Test("frame within all bounds passes")
    func withinAllBounds() throws {
        let filter = try FrameFilter(specs: ["minX=10,maxX=200,minY=50,maxY=400"])
        let frame = try makeFrame(x: 50, y: 100)
        #expect(filter.contains(frame))
    }

    @Test("frame at exact boundary is included (inclusive)")
    func exactBoundary() throws {
        let filter = try FrameFilter(specs: ["minX=50,maxX=200"])
        let lower = try makeFrame(x: 50, y: 0)
        let upper = try makeFrame(x: 200, y: 0)
        #expect(filter.contains(lower))
        #expect(filter.contains(upper))
    }

    @Test("frame below minY rejected")
    func belowMinY() throws {
        let filter = try FrameFilter(specs: ["minY=100"])
        let frame = try makeFrame(x: 0, y: 50)
        #expect(!filter.contains(frame))
    }

    @Test("frame above maxY rejected")
    func aboveMaxY() throws {
        let filter = try FrameFilter(specs: ["maxY=100"])
        let frame = try makeFrame(x: 0, y: 200)
        #expect(!filter.contains(frame))
    }

    @Test("only minY set — y above passes regardless of x")
    func partialBoundsOnlyMinY() throws {
        let filter = try FrameFilter(specs: ["minY=100"])
        let near = try makeFrame(x: 9999, y: 100)
        #expect(filter.contains(near))
    }
}

// MARK: - resolved()

@Suite("FrameFilter resolved() — relative→absolute math")
struct FrameFilterResolvedTests {
    @Test("rel 0.7 of width=400 origin=0 yields 280")
    func zeroOriginScreen() throws {
        let filter = try FrameFilter(specs: ["minX=0.7r"])
        let screen = try makeFrame(x: 0, y: 0, w: 400, h: 800)
        let resolved = filter.resolved(screen: screen)
        #expect(resolved.minX == 280)
        #expect(resolved.minXRel == nil)
    }

    @Test("non-zero screen origin is honoured")
    func nonZeroOrigin() throws {
        let filter = try FrameFilter(specs: ["minX=0.5r"])
        let screen = try makeFrame(x: 10, y: 0, w: 400, h: 800)
        let resolved = filter.resolved(screen: screen)
        #expect(resolved.minX == 210)
    }

    @Test("rel y resolves against height and screen y origin")
    func yAxisResolution() throws {
        let filter = try FrameFilter(specs: ["maxY=0.5r"])
        let screen = try makeFrame(x: 0, y: 20, w: 400, h: 800)
        let resolved = filter.resolved(screen: screen)
        #expect(resolved.maxY == 420)
    }

    @Test("abs bounds are passed through untouched while rel bounds are projected")
    func mixedAbsRel() throws {
        let filter = try FrameFilter(specs: ["minX=10,minY=0.5r"])
        let screen = try makeFrame(x: 0, y: 0, w: 400, h: 800)
        let resolved = filter.resolved(screen: screen)
        #expect(resolved.minX == 10)
        #expect(resolved.minY == 400)
        #expect(resolved.minYRel == nil)
    }

    @Test("resolved filter no longer reports relative bounds")
    func noRelAfterResolve() throws {
        let filter = try FrameFilter(specs: ["minY=0.6r"])
        let screen = try makeFrame(x: 0, y: 0, w: 400, h: 800)
        let resolved = filter.resolved(screen: screen)
        #expect(!resolved.hasRelativeBounds)
    }
}