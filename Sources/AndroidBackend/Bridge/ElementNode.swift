// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Wire schema for an accessibility node as emitted by
/// `sim-use-device-bridge`'s `/a11y_tree_full` endpoint. Matches the full
/// P0+P1 field set of the bridge's `model/ElementNode.kt` — keep the
/// two field sets in sync. Fields
/// that may be absent on older Android versions are modeled as `nil`
/// rather than forced to defaults so the normalizer can tell "absent"
/// from "empty".
public struct ElementNode: Codable, Equatable, Sendable {
    // Identifiers
    public let resourceId: String
    public let uniqueId: String?
    public let package: String

    // Class & labels
    public let className: String
    public let text: String
    public let contentDescription: String
    public let hintText: String?
    public let stateDescription: String?

    // Geometry
    public let boundsInScreen: Rect

    // Interaction flags
    public let clickable: Bool
    public let longClickable: Bool
    public let scrollable: Bool
    public let focusable: Bool
    public let focused: Bool
    public let enabled: Bool
    public let checkable: Bool
    public let checked: Bool
    public let selected: Bool
    public let password: Bool

    // Visibility — `AccessibilityNodeInfo.isVisibleToUser()` on the
    // bridge side. False for stale fragment subtrees that haven't been
    // detached yet, or nodes hidden behind another opaque view. Older
    // bridges (pre-this-wire-bump) omit the field; default `true` keeps
    // the renderer behaving the way it used to.
    public let visibleToUser: Bool

    // Collection metadata
    public let collectionInfo: CollectionInfo?
    public let collectionItemInfo: CollectionItemInfo?

    // Tree
    public let children: [ElementNode]

    public struct Rect: Codable, Equatable, Hashable, Sendable {
        public let left: Int
        public let top: Int
        public let right: Int
        public let bottom: Int

        public init(left: Int, top: Int, right: Int, bottom: Int) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
        }

        public var width: Int { right - left }
        public var height: Int { bottom - top }

        public func toFrame() -> Outline.Frame {
            Outline.Frame(x: left, y: top, width: max(0, width), height: max(0, height))
        }
    }

    public struct CollectionInfo: Codable, Equatable, Sendable {
        public let rowCount: Int
        public let columnCount: Int
        public let itemCount: Int
        public let isHierarchical: Bool

        public init(rowCount: Int, columnCount: Int, itemCount: Int, isHierarchical: Bool) {
            self.rowCount = rowCount
            self.columnCount = columnCount
            self.itemCount = itemCount
            self.isHierarchical = isHierarchical
        }
    }

    public struct CollectionItemInfo: Codable, Equatable, Sendable {
        public let rowIndex: Int
        public let columnIndex: Int
        public let rowSpan: Int
        public let columnSpan: Int
        public let isHeading: Bool

        public init(rowIndex: Int, columnIndex: Int, rowSpan: Int, columnSpan: Int, isHeading: Bool) {
            self.rowIndex = rowIndex
            self.columnIndex = columnIndex
            self.rowSpan = rowSpan
            self.columnSpan = columnSpan
            self.isHeading = isHeading
        }
    }

    // Custom decode keeps backward compat with bridges from before
    // the `visibleToUser` wire bump — older payloads omit the field
    // entirely, in which case we default `true` so the renderer's
    // visibility filter is a no-op (matching pre-bump behaviour).
    private enum CodingKeys: String, CodingKey {
        case resourceId, uniqueId, `package`, className, text, contentDescription
        case hintText, stateDescription, boundsInScreen
        case clickable, longClickable, scrollable, focusable, focused, enabled
        case checkable, checked, selected, password, visibleToUser
        case collectionInfo, collectionItemInfo, children
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resourceId = try c.decode(String.self, forKey: .resourceId)
        uniqueId = try c.decodeIfPresent(String.self, forKey: .uniqueId)
        package = try c.decode(String.self, forKey: .package)
        className = try c.decode(String.self, forKey: .className)
        text = try c.decode(String.self, forKey: .text)
        contentDescription = try c.decode(String.self, forKey: .contentDescription)
        hintText = try c.decodeIfPresent(String.self, forKey: .hintText)
        stateDescription = try c.decodeIfPresent(String.self, forKey: .stateDescription)
        boundsInScreen = try c.decode(Rect.self, forKey: .boundsInScreen)
        // Forward-compat: older bridge builds (pre-this-wire-bump)
        // may omit individual interaction-flag fields when the
        // underlying `AccessibilityNodeInfo` couldn't supply them.
        // Defaulting here lets the renderer survive a partial
        // payload — losing the whole node to a `keyNotFound` would
        // cascade into broken `@N` aliasing for everything below
        // it in the tree. Defaults match Android's own semantics:
        // a fresh View is `enabled`; every other state flag is false
        // unless the platform explicitly says otherwise.
        clickable = try c.decodeIfPresent(Bool.self, forKey: .clickable) ?? false
        longClickable = try c.decodeIfPresent(Bool.self, forKey: .longClickable) ?? false
        scrollable = try c.decodeIfPresent(Bool.self, forKey: .scrollable) ?? false
        focusable = try c.decodeIfPresent(Bool.self, forKey: .focusable) ?? false
        focused = try c.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        checkable = try c.decodeIfPresent(Bool.self, forKey: .checkable) ?? false
        checked = try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? false
        password = try c.decodeIfPresent(Bool.self, forKey: .password) ?? false
        visibleToUser = try c.decodeIfPresent(Bool.self, forKey: .visibleToUser) ?? true
        collectionInfo = try c.decodeIfPresent(CollectionInfo.self, forKey: .collectionInfo)
        collectionItemInfo = try c.decodeIfPresent(CollectionItemInfo.self, forKey: .collectionItemInfo)
        children = try c.decodeIfPresent([ElementNode].self, forKey: .children) ?? []
    }

    public init(
        resourceId: String,
        uniqueId: String? = nil,
        package: String,
        className: String,
        text: String,
        contentDescription: String,
        hintText: String? = nil,
        stateDescription: String? = nil,
        boundsInScreen: Rect,
        clickable: Bool = false,
        longClickable: Bool = false,
        scrollable: Bool = false,
        focusable: Bool = false,
        focused: Bool = false,
        enabled: Bool = true,
        checkable: Bool = false,
        checked: Bool = false,
        selected: Bool = false,
        password: Bool = false,
        visibleToUser: Bool = true,
        collectionInfo: CollectionInfo? = nil,
        collectionItemInfo: CollectionItemInfo? = nil,
        children: [ElementNode] = []
    ) {
        self.resourceId = resourceId
        self.uniqueId = uniqueId
        self.package = package
        self.className = className
        self.text = text
        self.contentDescription = contentDescription
        self.hintText = hintText
        self.stateDescription = stateDescription
        self.boundsInScreen = boundsInScreen
        self.clickable = clickable
        self.longClickable = longClickable
        self.scrollable = scrollable
        self.focusable = focusable
        self.focused = focused
        self.enabled = enabled
        self.checkable = checkable
        self.checked = checked
        self.selected = selected
        self.password = password
        self.visibleToUser = visibleToUser
        self.collectionInfo = collectionInfo
        self.collectionItemInfo = collectionItemInfo
        self.children = children
    }
}

extension ElementNode {
    /// Short-form `resource_id` (the part after `:id/`). Empty when the
    /// wire field is absent or unparseable. Used as the canonical
    /// `--id` match value, per the wire spec.
    public var resourceIdShortName: String {
        guard let slash = resourceId.lastIndex(of: "/") else { return resourceId }
        return String(resourceId[resourceId.index(after: slash)...])
    }
}