// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import iOSSimBackend

/// Pins the semantics `streamBGRA` relies on: the box is empty until an
/// error is set, the first error wins (later sets are no-ops), and
/// concurrent sets from callback queues elect exactly one winner.
@Suite("FirstErrorBox — set-once error capture")
struct FirstErrorBoxTests {

    private struct StubError: Error, Equatable {
        let id: Int
    }

    @Test("Empty until an error is set")
    func emptyBeforeSet() {
        let box = FirstErrorBox()
        #expect(box.first == nil)
    }

    @Test("Read after set returns the stored error")
    func readAfterSet() {
        let box = FirstErrorBox()
        box.set(StubError(id: 1))
        #expect(box.first as? StubError == StubError(id: 1))
    }

    @Test("First error wins; later sets are ignored")
    func firstErrorWins() {
        let box = FirstErrorBox()
        box.set(StubError(id: 1))
        box.set(StubError(id: 2))
        #expect(box.first as? StubError == StubError(id: 1))
    }

    @Test("Concurrent sets elect exactly one stable winner")
    func concurrentSetsSingleWinner() {
        let box = FirstErrorBox()
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            box.set(StubError(id: index))
        }
        let winner = box.first as? StubError
        #expect(winner != nil)
        // The value must not change once observed.
        #expect(box.first as? StubError == winner)
    }
}
