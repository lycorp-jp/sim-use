// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Suite("Android Swipe & Scroll Tests", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidSwipeScrollTests {
    @Test("Swipe up is echoed as direction up")
    func swipeUpDirection() async throws {
        try await AndroidE2E.launch(screen: "swipe-test")
        let area = try #require(try await AndroidE2E.describeUI().entry(resourceId: "swipe_test_area"))
        let cx = area.frame.x + area.frame.width / 2
        let yTop = area.frame.y + area.frame.height / 4
        let yBottom = area.frame.y + area.frame.height * 3 / 4

        try await AndroidE2E.run("swipe --from \(cx),\(yBottom) --to \(cx),\(yTop)")

        let ui = try await AndroidE2E.waitForOutline {
            AndroidE2E.trailingValue($0.label(resourceId: "last_swipe_direction")) == "up"
        }
        #expect(AndroidE2E.trailingValue(ui.label(resourceId: "last_swipe_direction")) == "up")
        #expect((AndroidE2E.trailingInt(ui.label(resourceId: "swipe_count")) ?? 0) >= 1)
    }

    @Test("android scroll moves the list")
    func androidScrollMovesList() async throws {
        try await AndroidE2E.launch(screen: "scroll-test")
        let before = AndroidE2E.trailingValue(
            try await AndroidE2E.describeUI().label(resourceId: "first_visible_row")
        )

        try await AndroidE2E.run("android scroll --direction down --distance 900")

        let ui = try await AndroidE2E.waitForOutline {
            AndroidE2E.trailingValue($0.label(resourceId: "first_visible_row")) != before
        }
        let after = AndroidE2E.trailingValue(ui.label(resourceId: "first_visible_row"))
        #expect(before != after, "first_visible_row should change after scroll (was \(before ?? "nil"))")
    }

    @Test("Gesture preset scroll moves the list")
    func gestureScrollPresetMovesList() async throws {
        try await AndroidE2E.launch(screen: "scroll-test")
        let before = AndroidE2E.trailingValue(
            try await AndroidE2E.describeUI().label(resourceId: "first_visible_row")
        )

        // `gesture scroll-*` presets are named by *finger* direction, the
        // opposite of `android scroll --direction`: from the top, only a
        // finger-up swipe (`scroll-up`) reveals later rows.
        try await AndroidE2E.run("android gesture scroll-up")

        let ui = try await AndroidE2E.waitForOutline {
            AndroidE2E.trailingValue($0.label(resourceId: "first_visible_row")) != before
        }
        let after = AndroidE2E.trailingValue(ui.label(resourceId: "first_visible_row"))
        #expect(before != after, "first_visible_row should change after gesture scroll (was \(before ?? "nil"))")
    }
}
