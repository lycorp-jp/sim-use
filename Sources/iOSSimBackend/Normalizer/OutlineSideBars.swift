// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Detects a vertical bar of system chrome along one side of the app —
/// what an iOS 27.1 SDK app shows on the iPhone Duo cover display, and on
/// the inner display in landscape: the back button, trailing toolbar items
/// and the tab bar stacked in a narrow strip (Apple: 84 pt) at the edge.
///
/// The bar is gated on evidence, not on a device table, so a tree without
/// one renders exactly as before:
///
/// 1. An anchor sits in a narrow strip at the edge: the `BackButton`
///    identifier or a tab item (`RadioButton` / `Tab`).
/// 2. At least two elements in the anchor's column, stacked vertically.
/// 3. The app's wide content stays clear of the bar: at least one wide
///    element exists, and nothing except a container (full screen, or a
///    full-width group) crosses the bar's inner edge. On a regular iPhone
///    the back button and row icons share the leading strip, but every
///    row runs across it.
///
/// Work record: docs/ai/010-display-routing/000-plan.md (S4).
enum OutlineSideBars {
    enum Edge: String {
        case leading = "Leading"
        case trailing = "Trailing"
    }

    struct Bar: Equatable {
        let edge: Edge
        /// The bar's inner edge: elements at `x <= boundary` (leading) or
        /// `x >= boundary` (trailing) belong to it.
        let boundary: Int

        func contains(_ frame: Outline.Frame) -> Bool {
            guard frame.width <= OutlineSideBars.maxBarWidth else { return false }
            switch edge {
            case .leading: return frame.x + frame.width <= boundary
            case .trailing: return frame.x >= boundary
            }
        }
    }

    struct Item {
        let frame: Outline.Frame
        let role: String?
        let uniqueId: String?
    }

    /// Wider than Apple's 84 pt bar plus its margins; narrow enough that a
    /// content column does not qualify.
    static let maxBarWidth = 120

    private static let anchorRoles: Set<String> = ["RadioButton", "Tab"]

    static func detect(_ items: [Item], screen: Outline.Frame) -> [Bar] {
        guard screen.width > maxBarWidth * 2, screen.height > 0 else { return [] }
        return [Edge.leading, .trailing].compactMap { bar(at: $0, items: items, screen: screen) }
    }

    private static func bar(at edge: Edge, items: [Item], screen: Outline.Frame) -> Bar? {
        func inStrip(_ f: Outline.Frame) -> Bool {
            guard f.width <= maxBarWidth else { return false }
            switch edge {
            case .leading: return f.x + f.width <= maxBarWidth
            case .trailing: return f.x >= screen.width - maxBarWidth
            }
        }
        let candidates = items.filter { inStrip($0.frame) }
        let anchors = candidates.filter { $0.uniqueId == "BackButton" || $0.role.map(anchorRoles.contains) == true }
        guard let firstAnchor = anchors.first else { return nil }

        // The bar is one column: the candidates that overlap the anchors
        // horizontally.
        let columnMinX = anchors.map(\.frame.x).min() ?? firstAnchor.frame.x
        let columnMaxX = anchors.map { $0.frame.x + $0.frame.width }.max() ?? firstAnchor.frame.x
        let members = candidates.filter { $0.frame.x < columnMaxX && $0.frame.x + $0.frame.width > columnMinX }
        guard isStackedVertically(members.map(\.frame)) else { return nil }

        let boundary: Int
        switch edge {
        case .leading: boundary = members.map { $0.frame.x + $0.frame.width }.max() ?? 0
        case .trailing: boundary = members.map(\.frame.x).min() ?? screen.width
        }

        // Content stays on its own side of the bar.
        let content = items.filter { !isContainer($0, screen: screen) }.map(\.frame)
        guard content.contains(where: { $0.width * 2 >= screen.width }) else { return nil }
        let crossed = content.contains { $0.x < boundary && $0.x + $0.width > boundary }
        guard !crossed else { return nil }
        return Bar(edge: edge, boundary: boundary)
    }

    /// At least two frames whose vertical ranges do not overlap.
    private static func isStackedVertically(_ frames: [Outline.Frame]) -> Bool {
        let sorted = frames.sorted { $0.y < $1.y }
        guard let first = sorted.first else { return false }
        return sorted.dropFirst().contains { $0.y >= first.y + first.height }
    }

    /// Roles that only group other elements. A full-width one (the group a
    /// navigation bar leaves behind when its items move into the bar)
    /// says nothing about where the content ends; a full-width button or
    /// cell does.
    private static let groupingRoles: Set<String> = ["Group", "GenericElement", "ScrollView"]

    /// A view that spans (nearly) the whole screen — the window, a
    /// full-screen group — or a full-width grouping element.
    private static func isContainer(_ item: Item, screen: Outline.Frame) -> Bool {
        let f = item.frame
        guard f.width * 10 >= screen.width * 9 else { return false }
        return f.height * 10 >= screen.height * 9 || item.role.map(groupingRoles.contains) == true
    }
}
