// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Structured result of rendering an accessibility tree to the outline
/// format defined in `DESCRIBE_UI_OUTLINE.md`.
///
/// Cross-platform shape consumed by both iOS and Android backends.
/// `text` is the human-facing stdout payload for `describe-ui`. `entries`
/// is the same information in structured form and is what `--json`
/// surfaces and what the `@N`/`#N` alias cache is derived from. `lists`
/// summarises every detected list cluster in dominance order so
/// consumers that prefer to reason explicitly about lists can skip the
/// entries walk.
public struct Outline: Equatable, Sendable {
    public let text: String
    public let entries: [Entry]
    public let lists: [ListSummary]
    public let screen: Frame
    public let appLabel: String

    public init(
        text: String,
        entries: [Entry],
        lists: [ListSummary] = [],
        screen: Frame,
        appLabel: String
    ) {
        self.text = text
        self.entries = entries
        self.lists = lists
        self.screen = screen
        self.appLabel = appLabel
    }

    /// One element as it appears in the outline. Carries the addressable
    /// handles (`@N`, optional `#N` / `#N@M`) and per-platform descriptor
    /// fields. `value` / `resource_id` / `hint` are optional cross-
    /// platform extensions added for the Android backend; iOS populates
    /// `value` from AXValue and leaves the other two nil.
    public struct Entry: Codable, Equatable, Sendable {
        public let aliases: Aliases
        public let role: String
        public let label: String
        public let frame: Frame
        public let region: Region
        public let states: [String]
        public let uniqueId: String?
        /// AXValue on iOS / `text` on Android. Optional because not every
        /// element carries a value distinct from `label`.
        public let value: String?
        /// Android `resource_id` short-name (e.g. `chats_tab` from
        /// `com.example.app:id/chats_tab`). Always nil on iOS.
        public let resourceId: String?
        /// Placeholder / hint text on EditText (Android `hintText`).
        /// Always nil on iOS today; reserved for future iOS placeholder
        /// support.
        public let hint: String?
        /// Raw depth in the accessibility tree from the application root.
        /// Used by the outline renderer to indent children under their
        /// parents, restoring the visual grouping the tree carries
        /// (e.g. icon + label pair inside an action-row cell). Default
        /// 0 so older fixtures / non-indenting callers stay valid.
        public let depth: Int

        public init(
            aliases: Aliases,
            role: String,
            label: String,
            frame: Frame,
            region: Region,
            states: [String],
            uniqueId: String? = nil,
            value: String? = nil,
            resourceId: String? = nil,
            hint: String? = nil,
            depth: Int = 0
        ) {
            self.aliases = aliases
            self.role = role
            self.label = label
            self.frame = frame
            self.region = region
            self.states = states
            self.uniqueId = uniqueId
            self.value = value
            self.resourceId = resourceId
            self.hint = hint
            self.depth = depth
        }

        enum CodingKeys: String, CodingKey {
            case aliases, role, label, frame, region, states, uniqueId, value
            case resourceId = "resource_id"
            case hint, depth
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            aliases = try container.decode(Aliases.self, forKey: .aliases)
            role = try container.decode(String.self, forKey: .role)
            label = try container.decode(String.self, forKey: .label)
            frame = try container.decode(Frame.self, forKey: .frame)
            region = try container.decode(Region.self, forKey: .region)
            states = try container.decode([String].self, forKey: .states)
            uniqueId = try container.decodeIfPresent(String.self, forKey: .uniqueId)
            value = try container.decodeIfPresent(String.self, forKey: .value)
            resourceId = try container.decodeIfPresent(String.self, forKey: .resourceId)
            hint = try container.decodeIfPresent(String.self, forKey: .hint)
            depth = try container.decodeIfPresent(Int.self, forKey: .depth) ?? 0
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(aliases, forKey: .aliases)
            try container.encode(role, forKey: .role)
            try container.encode(label, forKey: .label)
            try container.encode(frame, forKey: .frame)
            try container.encode(region, forKey: .region)
            try container.encode(states, forKey: .states)
            if let uniqueId { try container.encode(uniqueId, forKey: .uniqueId) }
            if let value { try container.encode(value, forKey: .value) }
            if let resourceId { try container.encode(resourceId, forKey: .resourceId) }
            if let hint { try container.encode(hint, forKey: .hint) }
            if depth != 0 { try container.encode(depth, forKey: .depth) }
        }
    }

    public struct Aliases: Codable, Equatable, Sendable {
        public let at: Int
        public let list: ListAlias?

        public init(at: Int, list: ListAlias? = nil) {
            self.at = at
            self.list = list
        }

        enum CodingKeys: String, CodingKey { case at, list }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            at = try container.decode(Int.self, forKey: .at)
            list = try container.decodeIfPresent(ListAlias.self, forKey: .list)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(at, forKey: .at)
            if let list { try container.encode(list, forKey: .list) }
        }
    }

    public struct ListAlias: Codable, Equatable, Sendable {
        public let scope: Int
        public let index: Int
        public init(scope: Int, index: Int) {
            self.scope = scope
            self.index = index
        }
    }

    public struct ListSummary: Codable, Equatable, Sendable {
        public let scope: Int
        public let cellCount: Int
        public let cellHeight: Int
        public let containerRole: String
        public let containerLabel: String?
        public let bbox: Frame
        public let score: Double

        public init(
            scope: Int,
            cellCount: Int,
            cellHeight: Int,
            containerRole: String,
            containerLabel: String?,
            bbox: Frame,
            score: Double
        ) {
            self.scope = scope
            self.cellCount = cellCount
            self.cellHeight = cellHeight
            self.containerRole = containerRole
            self.containerLabel = containerLabel
            self.bbox = bbox
            self.score = score
        }

        enum CodingKeys: String, CodingKey {
            case scope, cellCount, cellHeight, containerRole, containerLabel, bbox, score
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scope = try container.decode(Int.self, forKey: .scope)
            cellCount = try container.decode(Int.self, forKey: .cellCount)
            cellHeight = try container.decode(Int.self, forKey: .cellHeight)
            containerRole = try container.decode(String.self, forKey: .containerRole)
            containerLabel = try container.decodeIfPresent(String.self, forKey: .containerLabel)
            bbox = try container.decode(Frame.self, forKey: .bbox)
            score = try container.decode(Double.self, forKey: .score)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(scope, forKey: .scope)
            try container.encode(cellCount, forKey: .cellCount)
            try container.encode(cellHeight, forKey: .cellHeight)
            try container.encode(containerRole, forKey: .containerRole)
            if let containerLabel {
                try container.encode(containerLabel, forKey: .containerLabel)
            }
            try container.encode(bbox, forKey: .bbox)
            try container.encode(score, forKey: .score)
        }
    }

    public struct Region: Codable, Equatable, Sendable {
        public let kind: String
        public let label: String?

        public init(kind: String, label: String? = nil) {
            self.kind = kind
            self.label = label
        }

        enum CodingKeys: String, CodingKey { case kind, label }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            label = try container.decodeIfPresent(String.self, forKey: .label)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            if let label { try container.encode(label, forKey: .label) }
        }
    }

    /// Integer-rounded frame in **platform-native units**:
    ///
    ///   * iOS: points (`AccessibilityElement.frame`'s native unit;
    ///     the iPhone 15 logical screen is 390×844).
    ///   * Android: physical pixels (`ElementNode.boundsInScreen`'s
    ///     native unit; a typical phone is 1080×2400).
    ///
    /// Cross-platform consumers (Viewer, automation scripts) reading
    /// a bare `Outline.Frame` MUST consult `DescribeUIResult.platform`
    /// to know which unit they're working with — the two scales
    /// differ by ~5× and a hardcoded "120 px from top is the status
    /// bar" rule that's right on iOS lands inside the system status
    /// bar on Android. Renderers ship platform-specific anchors
    /// (`AndroidOutlineRenderer.yBandInset = 280` vs
    /// `OutlineFormatter.yBandInset = 120`) for this reason.
    public struct Frame: Codable, Equatable, Hashable, Sendable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }
}