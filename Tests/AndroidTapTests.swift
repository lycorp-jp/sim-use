// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Suite("Android Tap Tests", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidTapTests {
    @Test("Tap by #resource-id registers on the tap area")
    func tapByResourceId() async throws {
        try await AndroidE2E.launch(screen: "tap-test")
        try await AndroidE2E.run("tap '#tap_test_area'")

        let ui = try await AndroidE2E.waitForOutline {
            AndroidE2E.trailingInt($0.label(resourceId: "tap_count")) == 1
        }
        #expect(AndroidE2E.trailingInt(ui.label(resourceId: "tap_count")) == 1)
    }

    @Test("Tap by coordinates echoes the tapped point in pixels")
    func tapByCoordinates() async throws {
        try await AndroidE2E.launch(screen: "tap-test")
        let area = try #require(try await AndroidE2E.describeUI().entry(resourceId: "tap_test_area"))
        let cx = area.frame.x + area.frame.width / 2
        let cy = area.frame.y + area.frame.height / 2

        try await AndroidE2E.run("tap -x \(cx) -y \(cy)")

        // Wait until both the counter and the coordinate echo have settled.
        let ui = try await AndroidE2E.waitForOutline {
            AndroidE2E.trailingInt($0.label(resourceId: "tap_count")) == 1
                && (AndroidE2E.trailingValue($0.label(resourceId: "last_tap_coordinates")) ?? "-") != "-"
        }
        #expect(AndroidE2E.trailingInt(ui.label(resourceId: "tap_count")) == 1)

        // The playground echoes raw screen coordinates, which equal the
        // dispatched pixels; allow a couple px of rounding slack.
        let coords = AndroidE2E.trailingValue(ui.label(resourceId: "last_tap_coordinates")) ?? ""
        let parts = coords.split(separator: ",").compactMap { Int($0) }
        try #require(parts.count == 2, "expected 'x,y', got '\(coords)'")
        #expect(abs(parts[0] - cx) <= 5)
        #expect(abs(parts[1] - cy) <= 5)
    }

    @Test("Long-press registers as a long press and not a tap")
    func longPressDistinguishedFromTap() async throws {
        try await AndroidE2E.launch(screen: "tap-test")
        let area = try #require(try await AndroidE2E.describeUI().entry(resourceId: "tap_test_area"))
        let cx = area.frame.x + area.frame.width / 2
        let cy = area.frame.y + area.frame.height / 2

        // Default long-press hold is 0.8s, well past Android's long-press
        // timeout, so the GestureDetector fires onLongPress — never onTap.
        try await AndroidE2E.run("long-press -x \(cx) -y \(cy)")

        let ui = try await AndroidE2E.waitForOutline {
            AndroidE2E.trailingInt($0.label(resourceId: "long_press_count")) == 1
        }
        #expect(AndroidE2E.trailingInt(ui.label(resourceId: "long_press_count")) == 1)
        #expect(AndroidE2E.trailingInt(ui.label(resourceId: "tap_count")) == 0)
    }
}
