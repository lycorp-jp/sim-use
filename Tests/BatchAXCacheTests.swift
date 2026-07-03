// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import Testing

// Coverage for the `--ax-cache` policy plumbing. Historically the
// policy was parsed but never consulted — every selector resolution
// refetched the AX tree, so `perBatch` / `perStep` / `none` behaved
// identically. These tests pin the documented semantics at the unit
// level with an injected fetcher (no simulator needed); the live-UI
// counterparts are the SIM_USE_E2E-gated BatchTests.

@MainActor
private final class FakeAXFetcher {
    private(set) var fetchCount = 0
    /// Swappable between calls so a test can simulate on-screen state
    /// changing underneath a cached snapshot.
    var tree: [AccessibilityElement]

    init(tree: [AccessibilityElement]) {
        self.tree = tree
    }

    func fetch() -> [AccessibilityElement] {
        fetchCount += 1
        return tree
    }
}

/// Builds a flat root array of actionable Buttons, one per label,
/// each with a distinct non-empty frame so center-point resolution works.
private func makeButtonTree(labels: [String]) throws -> [AccessibilityElement] {
    let elements = labels.enumerated().map { index, label in
        """
        {"type": "Button", "frame": {"x": 0, "y": \(index * 100), "width": 100, "height": 40}, "AXLabel": "\(label)", "enabled": true}
        """
    }.joined(separator: ",")
    return try JSONDecoder().decode([AccessibilityElement].self, from: Data("[\(elements)]".utf8))
}

@MainActor
private func makeContext(
    policy: AXCachePolicy,
    fetcher: FakeAXFetcher,
    waitTimeout: TimeInterval = 0,
    pollInterval: TimeInterval = 0.01
) -> BatchContext {
    BatchContext(
        simulatorUDID: "FAKE-UDID",
        axCachePolicy: policy,
        typeSubmissionMode: .chunked,
        typeChunkSize: 200,
        waitTimeout: waitTimeout,
        pollInterval: pollInterval,
        fetchElements: { _, _ in fetcher.fetch() }
    )
}

private let quietLogger = SimUseLogger(writeToStdErr: false)

@Suite("Batch — AX cache policies (BatchContext)")
@MainActor
struct BatchContextAXCacheTests {
    @Test("perBatch serves one snapshot across step boundaries")
    func perBatchCachesAcrossSteps() async throws {
        let fetcher = FakeAXFetcher(tree: try makeButtonTree(labels: ["Old"]))
        let context = makeContext(policy: .perBatch, fetcher: fetcher)

        context.beginStep()
        let first = try await context.accessibilityRoots(logger: quietLogger)
        fetcher.tree = try makeButtonTree(labels: ["New"])
        context.beginStep()
        let second = try await context.accessibilityRoots(logger: quietLogger)

        #expect(fetcher.fetchCount == 1, "perBatch must fetch exactly once for the whole run")
        #expect(first.first?.AXLabel == "Old")
        #expect(second.first?.AXLabel == "Old", "second step must see the stale cached snapshot")
    }

    @Test("perBatch forceRefresh refetches and replaces the cache")
    func perBatchForceRefreshUpdatesCache() async throws {
        let fetcher = FakeAXFetcher(tree: try makeButtonTree(labels: ["Old"]))
        let context = makeContext(policy: .perBatch, fetcher: fetcher)

        _ = try await context.accessibilityRoots(logger: quietLogger)
        fetcher.tree = try makeButtonTree(labels: ["New"])
        let refreshed = try await context.accessibilityRoots(logger: quietLogger, forceRefresh: true)
        let cached = try await context.accessibilityRoots(logger: quietLogger)

        #expect(fetcher.fetchCount == 2, "forceRefresh must refetch; the follow-up call must not")
        #expect(refreshed.first?.AXLabel == "New")
        #expect(cached.first?.AXLabel == "New", "cache must hold the refreshed snapshot")
    }

    @Test("perStep caches within a step and clears at beginStep")
    func perStepClearsAtStepBoundary() async throws {
        let fetcher = FakeAXFetcher(tree: try makeButtonTree(labels: ["Old"]))
        let context = makeContext(policy: .perStep, fetcher: fetcher)

        context.beginStep()
        _ = try await context.accessibilityRoots(logger: quietLogger)
        _ = try await context.accessibilityRoots(logger: quietLogger)
        #expect(fetcher.fetchCount == 1, "within one step perStep must reuse the snapshot")

        fetcher.tree = try makeButtonTree(labels: ["New"])
        context.beginStep()
        let roots = try await context.accessibilityRoots(logger: quietLogger)
        #expect(fetcher.fetchCount == 2, "a new step must refetch under perStep")
        #expect(roots.first?.AXLabel == "New")
    }

    @Test("none always fetches, even within a step")
    func noneNeverCaches() async throws {
        let fetcher = FakeAXFetcher(tree: try makeButtonTree(labels: ["Old"]))
        let context = makeContext(policy: .none, fetcher: fetcher)

        context.beginStep()
        _ = try await context.accessibilityRoots(logger: quietLogger)
        fetcher.tree = try makeButtonTree(labels: ["New"])
        let roots = try await context.accessibilityRoots(logger: quietLogger)

        #expect(fetcher.fetchCount == 2, "policy none must fetch on every call")
        #expect(roots.first?.AXLabel == "New")
    }
}

@Suite("Batch — AX cache policies (poller provider)")
@MainActor
struct AccessibilityPollerProviderTests {
    @Test("poll ticks force-refresh: provider sees (false) then (true)")
    func pollTickForcesRefresh() async throws {
        let missTree = try makeButtonTree(labels: ["Other"])
        let hitTree = try makeButtonTree(labels: ["Target"])
        var providerCalls: [Bool] = []

        let point = try await AccessibilityPoller.resolveWithPolling(
            query: .label("Target"),
            simulatorUDID: "FAKE-UDID",
            waitTimeout: 2,
            pollInterval: 0.01,
            rootsProvider: { forceRefresh in
                providerCalls.append(forceRefresh)
                return forceRefresh ? hitTree : missTree
            },
            logger: quietLogger
        )

        #expect(providerCalls == [false, true],
                "initial attempt must respect the cache; poll ticks must bust it")
        #expect(point.x == 50)
        #expect(point.y == 20)
    }

    @Test("waitTimeout 0 makes a single cache-respecting attempt")
    func zeroTimeoutSingleAttempt() async throws {
        let missTree = try makeButtonTree(labels: ["Other"])
        var providerCalls: [Bool] = []

        await #expect(throws: ElementResolutionError.self) {
            _ = try await AccessibilityPoller.resolveWithPolling(
                query: .label("Target"),
                simulatorUDID: "FAKE-UDID",
                waitTimeout: 0,
                pollInterval: 0.01,
                rootsProvider: { forceRefresh in
                    providerCalls.append(forceRefresh)
                    return missTree
                },
                logger: quietLogger
            )
        }
        #expect(providerCalls == [false])
    }
}

@Suite("Batch — AX cache policies (step parser integration)")
@MainActor
struct BatchAXCacheStepParserTests {
    private func parseTap(label: String, context: BatchContext) async throws -> [BatchPrimitive] {
        context.beginStep()
        return try await BatchStepParser.parseStepTokens(
            ["tap", "--label", label],
            globalUDID: "FAKE-UDID",
            context: context,
            logger: quietLogger
        )
    }

    @Test("perBatch: two tap-by-label steps share one fetch")
    func perBatchSharesFetchAcrossTapSteps() async throws {
        let fetcher = FakeAXFetcher(tree: try makeButtonTree(labels: ["First", "Second"]))
        let context = makeContext(policy: .perBatch, fetcher: fetcher)

        _ = try await parseTap(label: "First", context: context)
        _ = try await parseTap(label: "Second", context: context)

        #expect(fetcher.fetchCount == 1)
    }

    @Test("perStep: each tap-by-label step fetches its own snapshot")
    func perStepFetchesPerTapStep() async throws {
        let fetcher = FakeAXFetcher(tree: try makeButtonTree(labels: ["First", "Second"]))
        let context = makeContext(policy: .perStep, fetcher: fetcher)

        _ = try await parseTap(label: "First", context: context)
        _ = try await parseTap(label: "Second", context: context)

        #expect(fetcher.fetchCount == 2)
    }

    // Unit mirror of the E2E "perBatch cache fails after state change"
    // (BatchTests.perBatchCacheCanFailOnStateChange): with waitTimeout 0
    // the second step resolves against the stale snapshot and must fail.
    @Test("perBatch + waitTimeout 0: stale snapshot fails a later step")
    func perBatchStaleSnapshotFailsLaterStep() async throws {
        let fetcher = FakeAXFetcher(tree: try makeButtonTree(labels: ["Trigger"]))
        let context = makeContext(policy: .perBatch, fetcher: fetcher)

        _ = try await parseTap(label: "Trigger", context: context)
        fetcher.tree = try makeButtonTree(labels: ["Trigger", "Target"])

        await #expect(throws: ElementResolutionError.self) {
            _ = try await parseTap(label: "Target", context: context)
        }
        #expect(fetcher.fetchCount == 1, "waitTimeout 0 must not refetch under perBatch")
    }

    // Unit mirror of the E2E "wait-timeout can wait for delayed element"
    // (BatchTests.waitTimeoutFindsDelayedElement): under the default
    // perBatch policy, poll ticks must bypass the cache and the refreshed
    // snapshot must replace it for later steps.
    @Test("perBatch + waitTimeout: polling refetches and updates the cache")
    func perBatchPollingBypassesAndUpdatesCache() async throws {
        let fetcher = FakeAXFetcher(tree: try makeButtonTree(labels: ["Trigger"]))
        let context = makeContext(policy: .perBatch, fetcher: fetcher, waitTimeout: 2)

        _ = try await parseTap(label: "Trigger", context: context)
        fetcher.tree = try makeButtonTree(labels: ["Trigger", "Delayed"])
        _ = try await parseTap(label: "Delayed", context: context)

        #expect(fetcher.fetchCount == 2, "one initial fetch + one forced poll refetch")

        let cached = try await context.accessibilityRoots(logger: quietLogger)
        #expect(fetcher.fetchCount == 2, "later reads must hit the refreshed cache")
        #expect(cached.contains { $0.AXLabel == "Delayed" })
    }
}
