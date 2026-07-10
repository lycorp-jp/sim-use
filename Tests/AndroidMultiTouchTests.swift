// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Suite("Android Multi-Touch Tests", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidMultiTouchTests {
    @Test("pinch-out drives pinch_scale above 1.0 with two pointers")
    func pinchOutIncreasesScale() async throws {
        try await AndroidE2E.launch(screen: "multi-touch")

        try await AndroidE2E.run("android gesture pinch-out")

        let ui = try await AndroidE2E.waitForOutline {
            (Double(AndroidE2E.trailingValue($0.label(resourceId: "pinch_scale")) ?? "") ?? 0) > 1.0
        }
        let scaleText = AndroidE2E.trailingValue(ui.label(resourceId: "pinch_scale"))
        let scale = Double(scaleText ?? "") ?? 0
        #expect(scale > 1.0, "pinch-out should push the cumulative scale above 1.0, got \(scaleText ?? "nil")")
        #expect((AndroidE2E.trailingInt(ui.label(resourceId: "pointer_count_max")) ?? 0) >= 2)
    }
}
