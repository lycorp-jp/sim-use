// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import Foundation
import Testing

// MARK: - Fixture helpers

private func axFrame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> String {
    "{{\(x), \(y)}, {\(w), \(h)}}"
}

private func frameDict(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [String: Any] {
    ["x": x, "y": y, "width": w, "height": h]
}

private func makeGroup(
    x: Double,
    y: Double,
    w: Double,
    h: Double,
    label: String,
    children: [[String: Any]] = [],
    synthesized: Bool = false
) -> [String: Any] {
    var node: [String: Any] = [
        "role": "AXGroup",
        "AXLabel": label,
        "AXFrame": axFrame(x, y, w, h),
        "frame": frameDict(x, y, w, h),
        "children": children,
    ]
    if synthesized {
        node["synthesized"] = true
    }
    return node
}

private func makeTabButton(
    x: Double,
    y: Double,
    w: Double,
    h: Double,
    label: String
) -> [String: Any] {
    [
        "role": "AXRadioButton",
        "subrole": "AXTabButton",
        "AXLabel": label,
        "AXFrame": axFrame(x, y, w, h),
        "frame": frameDict(x, y, w, h),
    ]
}

private func makeElement(
    role: String,
    x: Double,
    y: Double,
    w: Double,
    h: Double,
    label: String
) -> [String: Any] {
    [
        "role": role,
        "AXLabel": label,
        "AXFrame": axFrame(x, y, w, h),
        "frame": frameDict(x, y, w, h),
    ]
}

private func wrapInApp(_ children: [[String: Any]]) -> NSArray {
    let app: [String: Any] = [
        "role": "AXApplication",
        "AXLabel": "TestApp",
        "AXFrame": axFrame(0, 0, 400, 800),
        "frame": frameDict(0, 0, 400, 800),
        "children": children,
    ]
    return [app] as NSArray
}

@MainActor
private func tabBarChildren(of result: AnyObject) throws -> [[String: Any]] {
    let roots = try #require(result as? [[String: Any]])
    let app = try #require(roots.first)
    let appChildren = try #require(app["children"] as? [[String: Any]])
    let tabBar = try #require(appChildren.first)
    return try #require(tabBar["children"] as? [[String: Any]])
}

@MainActor
private func appChildren(of result: AnyObject) throws -> [[String: Any]] {
    let roots = try #require(result as? [[String: Any]])
    let app = try #require(roots.first)
    return try #require(app["children"] as? [[String: Any]])
}

// Phase-1-only recover: scope the walk to phase 1 so test fixtures with a
// large App frame don't incidentally trigger the phase-2 blind-zone scan.
@MainActor
private func recoverPhaseOne(
    in info: AnyObject,
    probe: @escaping CollapsedChildrenRecovery.PointProbe,
    logger: SimUseLogger = SimUseLogger(),
    maxProbes: Int = 100
) async throws -> AnyObject {
    try await CollapsedChildrenRecovery.recover(
        in: info,
        probe: probe,
        logger: logger,
        maxProbes: maxProbes,
        scanBlindZones: false
    )
}

// MARK: - Tests

@MainActor
struct CollapsedChildrenRecoveryTests {

    // MARK: - Phase 1: empty-AXGroup recovery

    @Test("Empty AXGroup gets synthesized children from probe hits")
    func synthesizesChildrenForEmptyGroup() async throws {
        let tabBar = makeGroup(x: 0, y: 720, w: 400, h: 80, label: "Tab Bar")
        let tree = wrapInApp([tabBar])

        var calls: [CGPoint] = []
        let probe: CollapsedChildrenRecovery.PointProbe = { point in
            calls.append(point)
            // Divide 0..<400 into three buckets; each returns a distinct button.
            let bucket = Int(point.x / (400.0 / 3.0))
            switch bucket {
            case 0:
                return makeTabButton(x: 20, y: 735, w: 90, h: 50, label: "Tab1")
            case 1:
                return makeTabButton(x: 155, y: 735, w: 90, h: 50, label: "Tab2")
            default:
                return makeTabButton(x: 290, y: 735, w: 90, h: 50, label: "Tab3")
            }
        }

        let result = try await recoverPhaseOne(in: tree, probe: probe)

        let children = try tabBarChildren(of: result)
        #expect(children.count == 3)
        #expect(children.allSatisfy { ($0["synthesized"] as? Bool) == true })
        let labels = children.compactMap { $0["AXLabel"] as? String }
        #expect(labels == ["Tab1", "Tab2", "Tab3"])
        // Quadtree probes must stay within the tab bar's bounding rect.
        #expect(calls.allSatisfy { 720 <= $0.y && $0.y <= 800 && 0 <= $0.x && $0.x <= 400 })
        // Horizontal samples should span across the full width.
        let xs = calls.map(\.x).sorted()
        if let first = xs.first, let last = xs.last {
            #expect(first >= 0 && last <= 400)
            #expect(last - first >= 200)
        }
    }

    @Test("Too-small AXGroup is skipped (no probes)")
    func tooSmallGroupNotProbed() async throws {
        let smallGroup = makeGroup(x: 10, y: 10, w: 50, h: 20, label: "Small")
        let tree = wrapInApp([smallGroup])

        var probeCount = 0
        let probe: CollapsedChildrenRecovery.PointProbe = { _ in
            probeCount += 1
            return nil
        }

        _ = try await recoverPhaseOne(in: tree, probe: probe)
        #expect(probeCount == 0)
    }

    @Test("Non-AXGroup empty container is not probed")
    func nonGroupEmptyContainerNotProbed() async throws {
        let emptyButton: [String: Any] = [
            "role": "AXButton",
            "AXLabel": "Some Button",
            "AXFrame": axFrame(0, 0, 400, 80),
            "frame": frameDict(0, 0, 400, 80),
            "children": [] as [[String: Any]],
        ]
        let tree = wrapInApp([emptyButton])

        var probeCount = 0
        let probe: CollapsedChildrenRecovery.PointProbe = { _ in
            probeCount += 1
            return nil
        }

        _ = try await recoverPhaseOne(in: tree, probe: probe)
        #expect(probeCount == 0)
    }

    @Test("Probe hits with the same frame as the parent are discarded")
    func probeReturningParentIsDiscarded() async throws {
        let tabBar = makeGroup(x: 0, y: 720, w: 400, h: 80, label: "Tab Bar")
        let tree = wrapInApp([tabBar])

        let probe: CollapsedChildrenRecovery.PointProbe = { _ in
            makeGroup(x: 0, y: 720, w: 400, h: 80, label: "Tab Bar")
        }

        let result = try await recoverPhaseOne(in: tree, probe: probe)
        let children = try tabBarChildren(of: result)
        #expect(children.isEmpty)
    }

    @Test("Probe hits outside the parent frame are filtered out")
    func probeOutsideParentFiltered() async throws {
        let tabBar = makeGroup(x: 0, y: 720, w: 400, h: 80, label: "Tab Bar")
        let tree = wrapInApp([tabBar])

        let probe: CollapsedChildrenRecovery.PointProbe = { _ in
            [
                "role": "AXButton",
                "AXLabel": "Far Away",
                "AXFrame": axFrame(0, 100, 50, 50),
                "frame": frameDict(0, 100, 50, 50),
            ]
        }

        let result = try await recoverPhaseOne(in: tree, probe: probe)
        let children = try tabBarChildren(of: result)
        #expect(children.isEmpty)
    }

    @Test("Repeated probe hits are deduped by frame+role+label")
    func duplicateHitsDeduped() async throws {
        let tabBar = makeGroup(x: 0, y: 720, w: 400, h: 80, label: "Tab Bar")
        let tree = wrapInApp([tabBar])

        let probe: CollapsedChildrenRecovery.PointProbe = { _ in
            makeTabButton(x: 100, y: 735, w: 200, h: 50, label: "WideTab")
        }

        let result = try await recoverPhaseOne(in: tree, probe: probe)
        let children = try tabBarChildren(of: result)
        #expect(children.count == 1)
        #expect(children.first?["AXLabel"] as? String == "WideTab")
        #expect((children.first?["synthesized"] as? Bool) == true)
    }

    @Test("Already-synthesized nodes are not re-probed")
    func synthesizedNodesNotReProbed() async throws {
        let synthesizedInner = makeGroup(
            x: 10,
            y: 730,
            w: 300,
            h: 60,
            label: "Already Synth",
            synthesized: true
        )
        let tabBar = makeGroup(x: 0, y: 720, w: 400, h: 80, label: "Tab Bar", children: [synthesizedInner])
        let tree = wrapInApp([tabBar])

        var probeCount = 0
        let probe: CollapsedChildrenRecovery.PointProbe = { _ in
            probeCount += 1
            return nil
        }

        _ = try await recoverPhaseOne(in: tree, probe: probe)
        #expect(probeCount == 0)
    }

    @Test("Container with existing children is never probed")
    func containerWithExistingChildrenNotProbed() async throws {
        let existingChild = makeTabButton(x: 50, y: 735, w: 60, h: 50, label: "Existing")
        let tabBar = makeGroup(
            x: 0,
            y: 720,
            w: 400,
            h: 80,
            label: "Tab Bar",
            children: [existingChild]
        )
        let tree = wrapInApp([tabBar])

        var probeCount = 0
        let probe: CollapsedChildrenRecovery.PointProbe = { _ in
            probeCount += 1
            return nil
        }

        let result = try await recoverPhaseOne(in: tree, probe: probe)
        let children = try tabBarChildren(of: result)
        #expect(probeCount == 0)
        #expect(children.count == 1)
        #expect(children.first?["AXLabel"] as? String == "Existing")
        #expect(children.first?["synthesized"] as? Bool == nil)
    }

    // MARK: - Phase 1: 2-D quadtree regression

    @Test("2-D grid: quadtree seed pass recovers all nine icons")
    func gridRecoversNineIcons() async throws {
        // 3x3 grid of 80 pt icons with 10 pt margins inside a 300x300 container.
        let iconSize: Double = 80
        var origins: [(x: Double, y: Double, label: String)] = []
        for row in 0..<3 {
            for col in 0..<3 {
                origins.append((
                    x: 10 + Double(col) * 100,
                    y: 10 + Double(row) * 100,
                    label: "Icon_\(row)_\(col)"
                ))
            }
        }

        let container = makeGroup(x: 0, y: 0, w: 300, h: 300, label: "Grid")
        let tree = wrapInApp([container])

        var probeCount = 0
        let probe: CollapsedChildrenRecovery.PointProbe = { point in
            probeCount += 1
            for origin in origins {
                if origin.x <= point.x, point.x < origin.x + iconSize,
                   origin.y <= point.y, point.y < origin.y + iconSize {
                    return makeTabButton(x: origin.x, y: origin.y, w: iconSize, h: iconSize, label: origin.label)
                }
            }
            return nil
        }

        let result = try await recoverPhaseOne(in: tree, probe: probe)
        let appKids = try appChildren(of: result)
        let gridChildren = try #require(appKids.first?["children"] as? [[String: Any]])

        #expect(gridChildren.count == 9)
        #expect(gridChildren.allSatisfy { ($0["synthesized"] as? Bool) == true })
        let labels = Set(gridChildren.compactMap { $0["AXLabel"] as? String })
        let expectedLabels: Set<String> = Set(origins.map(\.label))
        #expect(labels == expectedLabels)
    }

    @Test("Dominant element causes later probes to be skipped via the CoveredSet")
    func dominantElementSkipsCovered() async throws {
        // A single element covers ~80% of the container. Seed cells whose
        // centres fall inside that rectangle should be skipped without
        // issuing a probe.
        let container = makeGroup(x: 0, y: 0, w: 400, h: 400, label: "Dominant Container")
        let tree = wrapInApp([container])

        let huge = (x: 21.0, y: 21.0, w: 358.0, h: 358.0)
        var probeCount = 0
        let probe: CollapsedChildrenRecovery.PointProbe = { point in
            probeCount += 1
            if huge.x <= point.x, point.x < huge.x + huge.w,
               huge.y <= point.y, point.y < huge.y + huge.h {
                return makeTabButton(x: huge.x, y: huge.y, w: huge.w, h: huge.h, label: "Huge")
            }
            return nil
        }

        let result = try await recoverPhaseOne(in: tree, probe: probe)
        let appKids = try appChildren(of: result)
        let containerChildren = try #require(appKids.first?["children"] as? [[String: Any]])

        #expect(containerChildren.count == 1)
        #expect(containerChildren.first?["AXLabel"] as? String == "Huge")
        #expect(probeCount < 25)
    }

    @Test("Probe budget is honoured; algorithm returns partial result without crashing")
    func budgetExhaustion() async throws {
        let container = makeGroup(x: 0, y: 0, w: 1000, h: 1000, label: "Huge Region")
        let tree = wrapInApp([container])

        var probeCount = 0
        let probe: CollapsedChildrenRecovery.PointProbe = { _ in
            probeCount += 1
            return nil
        }

        let result = try await recoverPhaseOne(in: tree, probe: probe, maxProbes: 5)
        let appKids = try appChildren(of: result)
        let containerChildren = try #require(appKids.first?["children"] as? [[String: Any]])

        #expect(containerChildren.isEmpty)
        #expect(probeCount == 5)
    }

    @Test("shouldProbe: rejects small groups, non-groups, and synthesized nodes")
    func shouldProbeHeuristics() {
        let eligible = makeGroup(x: 0, y: 0, w: 200, h: 60, label: "Group")
        #expect(CollapsedChildrenRecovery.shouldProbe(eligible))

        let tooNarrow = makeGroup(x: 0, y: 0, w: 80, h: 60, label: "Narrow")
        #expect(!CollapsedChildrenRecovery.shouldProbe(tooNarrow))

        let tooShort = makeGroup(x: 0, y: 0, w: 200, h: 20, label: "Short")
        #expect(!CollapsedChildrenRecovery.shouldProbe(tooShort))

        let button: [String: Any] = [
            "role": "AXButton",
            "AXLabel": "Btn",
            "AXFrame": axFrame(0, 0, 200, 60),
            "frame": frameDict(0, 0, 200, 60),
        ]
        #expect(!CollapsedChildrenRecovery.shouldProbe(button))

        let synth = makeGroup(x: 0, y: 0, w: 200, h: 60, label: "Synth", synthesized: true)
        #expect(!CollapsedChildrenRecovery.shouldProbe(synth))

        let noFrame: [String: Any] = [
            "role": "AXGroup",
            "AXLabel": "No frame",
        ]
        #expect(!CollapsedChildrenRecovery.shouldProbe(noFrame))
    }

    // MARK: - Phase 2: blind-zone recovery

    @Test("Blind zone between siblings is scanned and missing content synthesized")
    func blindZoneDiscoversHiddenElements() async throws {
        // App chrome: a small header button at the top. Tab bar at the
        // bottom with two tabs covering its full width — so phase 2 does
        // not fire on the tab bar itself and the full probe budget is
        // available for the App-level WebView blind zone.
        let header = makeElement(role: "AXButton", x: 20, y: 20, w: 100, h: 40, label: "Menu")
        let tabBar = makeGroup(x: 0, y: 720, w: 400, h: 80, label: "Tab Bar", children: [
            makeTabButton(x: 0, y: 720, w: 200, h: 80, label: "Home"),
            makeTabButton(x: 200, y: 720, w: 200, h: 80, label: "Settings"),
        ])
        let tree = wrapInApp([header, tabBar])

        // WebView content simulated: several distinct elements, each the
        // topmost hit for points that fall inside their frame.
        let webElements: [(x: Double, y: Double, w: Double, h: Double, label: String, role: String)] = [
            (x: 20, y: 100, w: 360, h: 80, label: "Hero heading", role: "AXHeading"),
            (x: 20, y: 200, w: 360, h: 60, label: "Play video", role: "AXButton"),
            (x: 20, y: 300, w: 360, h: 200, label: "Article body", role: "AXStaticText"),
            (x: 20, y: 520, w: 360, h: 80, label: "Related link", role: "AXLink"),
        ]

        var probeCount = 0
        let probe: CollapsedChildrenRecovery.PointProbe = { point in
            probeCount += 1
            for e in webElements
            where e.x <= point.x && point.x < e.x + e.w
                && e.y <= point.y && point.y < e.y + e.h {
                return makeElement(role: e.role, x: e.x, y: e.y, w: e.w, h: e.h, label: e.label)
            }
            return nil
        }

        let result = try await CollapsedChildrenRecovery.recover(
            in: tree,
            probe: probe,
            logger: SimUseLogger()
        )

        let kids = try appChildren(of: result)
        let synthesized = kids.filter { ($0["synthesized"] as? Bool) == true }
        let labels = Set(synthesized.compactMap { $0["AXLabel"] as? String })

        #expect(labels == Set(webElements.map(\.label)))
        // All original children are preserved.
        #expect(kids.contains(where: { $0["AXLabel"] as? String == "Menu" }))
        #expect(kids.contains(where: { $0["AXLabel"] as? String == "Tab Bar" }))
    }

    @Test("Blind zones smaller than the threshold are skipped")
    func smallBlindZonesFiltered() async throws {
        // Container entirely covered by two big children except for a
        // narrow padding gap. The gap is below the phase 2 min-dim
        // threshold and must not trigger a probe. Non-AXGroup roles
        // so phase 1 does not fire on the children.
        let topHalf = makeElement(role: "AXStaticText", x: 0, y: 0, w: 400, h: 395, label: "Top")
        let bottomHalf = makeElement(role: "AXStaticText", x: 0, y: 405, w: 400, h: 395, label: "Bottom")
        // Gap is a 400x10 strip — min dim below threshold.
        let tree = wrapInApp([topHalf, bottomHalf])

        var probeCount = 0
        let probe: CollapsedChildrenRecovery.PointProbe = { _ in
            probeCount += 1
            return nil
        }

        _ = try await CollapsedChildrenRecovery.recover(
            in: tree,
            probe: probe,
            logger: SimUseLogger()
        )
        #expect(probeCount == 0)
    }

    @Test("Blind-zone hits inside an existing child frame are rejected as descendants")
    func blindZoneRejectsDescendants() async throws {
        // A banner that covers most of the App, leaves a sliver of blind
        // zone at the bottom. Every probe in that blind zone happens to
        // return a point INSIDE the banner — classic descendant case that
        // must be deduped so we don't double-report it at App level.
        let banner = makeElement(role: "AXGroup", x: 0, y: 0, w: 400, h: 600, label: "Banner")
        let tree = wrapInApp([banner])

        let probe: CollapsedChildrenRecovery.PointProbe = { _ in
            // Whatever point we're asked about, claim it's a deeply nested
            // element whose frame sits fully inside the banner.
            makeElement(role: "AXStaticText", x: 50, y: 50, w: 200, h: 30, label: "Inside Banner")
        }

        let result = try await CollapsedChildrenRecovery.recover(
            in: tree,
            probe: probe,
            logger: SimUseLogger()
        )

        let kids = try appChildren(of: result)
        // Only the original Banner must remain; the hit is a descendant of it.
        #expect(kids.count == 1)
        #expect(kids.first?["AXLabel"] as? String == "Banner")
        #expect(kids.first?["synthesized"] as? Bool == nil)
    }

    @Test("Probe budget is shared across phase 1 and phase 2")
    func budgetSharedAcrossPhases() async throws {
        // Phase 1 exhausts the budget on the empty tab bar so phase 2 has
        // nothing left for the App-level blind zone.
        let tabBar = makeGroup(x: 0, y: 720, w: 400, h: 80, label: "Tab Bar")
        let tree = wrapInApp([tabBar])

        var probeCount = 0
        let probe: CollapsedChildrenRecovery.PointProbe = { _ in
            probeCount += 1
            return nil
        }

        _ = try await CollapsedChildrenRecovery.recover(
            in: tree,
            probe: probe,
            logger: SimUseLogger(),
            maxProbes: 3
        )
        #expect(probeCount == 3)
    }

    @Test("computeBlindZones returns the container when no children are present")
    func blindZoneGeometryNoCovers() {
        let region = CGRect(x: 0, y: 0, width: 400, height: 800)
        let zones = CollapsedChildrenRecovery.computeBlindZones(in: region, coveredBy: [])
        #expect(zones == [region])
    }

    @Test("computeBlindZones merges vertically adjacent strips with identical x-span")
    func blindZoneGeometryVerticalMerge() {
        // Two stacked children both occupying x=100..200. Horizontal
        // strip decomposition will emit two left gaps and two right
        // gaps, each with identical x-span across the two strips.
        // The vertical merge pass must collapse them into two tall
        // rectangles rather than four short ones.
        let region = CGRect(x: 0, y: 0, width: 400, height: 800)
        let upper = CGRect(x: 100, y: 0, width: 100, height: 400)
        let lower = CGRect(x: 100, y: 400, width: 100, height: 400)
        let zones = CollapsedChildrenRecovery.computeBlindZones(in: region, coveredBy: [upper, lower])

        let leftColumn = CGRect(x: 0, y: 0, width: 100, height: 800)
        let rightColumn = CGRect(x: 200, y: 0, width: 200, height: 800)
        #expect(zones.contains(leftColumn))
        #expect(zones.contains(rightColumn))
        #expect(zones.count == 2)
    }

    // MARK: - Cross-sibling (traversal-scoped) dedup

    @Test("Same element probed from two sibling AXGroups is synthesized only once")
    func crossSiblingDedupSameElement() async throws {
        // UIKit's AX translator sometimes layers a nav bar into multiple empty
        // AXGroup wrappers occupying overlapping frames. Each wrapper's probe
        // pass hit-tests the same on-screen button. With per-parent dedup only
        // (pre-fix) the button is synthesized once per wrapper, surfacing as a
        // duplicate. The traversal-scoped seen set collapses it to one entry.
        let wrapper1 = makeGroup(x: 0, y: 0, w: 400, h: 80, label: "NavWrap1")
        let wrapper2 = makeGroup(x: 0, y: 0, w: 400, h: 80, label: "NavWrap2")
        let tree = wrapInApp([wrapper1, wrapper2])

        let probe: CollapsedChildrenRecovery.PointProbe = { _ in
            makeElement(role: "AXButton", x: 10, y: 20, w: 50, h: 40, label: "Back")
        }

        let result = try await recoverPhaseOne(in: tree, probe: probe)
        let appKids = try appChildren(of: result)

        let synthesizedBacks = appKids.flatMap { wrapper -> [[String: Any]] in
            (wrapper["children"] as? [[String: Any]]) ?? []
        }
        .filter { ($0["synthesized"] as? Bool) == true && ($0["AXLabel"] as? String) == "Back" }

        #expect(synthesizedBacks.count == 1)
    }

    @Test("Probe hits matching an element already in the original tree are not re-synthesized")
    func prepopulatedIdentityPreventsDuplicateSynthesis() async throws {
        // wrapperA already exposes the Back button natively; wrapperB is an
        // empty AXGroup whose probe happens to hit the same button (its frame
        // overlaps wrapperA). Without pre-population the synthesized hit in
        // wrapperB becomes a duplicate of wrapperA's original child.
        let originalBack = makeElement(role: "AXButton", x: 10, y: 20, w: 50, h: 40, label: "Back")
        let wrapperA = makeGroup(
            x: 0,
            y: 0,
            w: 200,
            h: 80,
            label: "NavWrapA",
            children: [originalBack]
        )
        let wrapperB = makeGroup(x: 0, y: 0, w: 400, h: 80, label: "NavWrapB")
        let tree = wrapInApp([wrapperA, wrapperB])

        let probe: CollapsedChildrenRecovery.PointProbe = { _ in
            makeElement(role: "AXButton", x: 10, y: 20, w: 50, h: 40, label: "Back")
        }

        let result = try await recoverPhaseOne(in: tree, probe: probe)
        let appKids = try appChildren(of: result)

        let allBacks = appKids.flatMap { wrapper -> [[String: Any]] in
            (wrapper["children"] as? [[String: Any]]) ?? []
        }
        .filter { ($0["AXLabel"] as? String) == "Back" }

        #expect(allBacks.count == 1)
        // The surviving Back is wrapperA's original, not a synthesized copy.
        #expect((allBacks.first?["synthesized"] as? Bool) == nil)
    }

    @Test("Cross-sibling dedup preserves each unique synthesized element exactly once")
    func crossSiblingDedupPreservesDistinctElements() async throws {
        // Two overlapping sibling wrappers; probes return two distinct buttons
        // depending on the sampled x position. The merged tree must contain
        // each button exactly once — not duplicated across wrappers.
        let wrapper1 = makeGroup(x: 0, y: 0, w: 400, h: 80, label: "NavWrap1")
        let wrapper2 = makeGroup(x: 0, y: 0, w: 400, h: 80, label: "NavWrap2")
        let tree = wrapInApp([wrapper1, wrapper2])

        let probe: CollapsedChildrenRecovery.PointProbe = { point in
            if point.x < 200 {
                return makeElement(role: "AXButton", x: 10, y: 20, w: 80, h: 40, label: "Back")
            } else {
                return makeElement(role: "AXButton", x: 300, y: 20, w: 80, h: 40, label: "Menu")
            }
        }

        let result = try await recoverPhaseOne(in: tree, probe: probe)
        let appKids = try appChildren(of: result)

        let synthesized = appKids.flatMap { wrapper -> [[String: Any]] in
            (wrapper["children"] as? [[String: Any]]) ?? []
        }
        .filter { ($0["synthesized"] as? Bool) == true }

        let labels = synthesized.compactMap { $0["AXLabel"] as? String }.sorted()
        #expect(labels == ["Back", "Menu"])
    }
}